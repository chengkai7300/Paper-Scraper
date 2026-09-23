"""history.py - 历史记录回溯 / 增量评价 / 前后对比

要解决的问题
------------
`main.py` 的常规流程只评测"本次新抓到的论文"，`papers_metadata.json` 里
的历史记录（尤其是用旧权重评过的）永远不会被重算。一旦调整评分权重，
历史记录中的 `evaluation` 就变成了过期数据：

  * 无法与新论文按同一口径比较；
  * 看不出权重调整究竟把排序改成了什么样。

本模块提供三件事
----------------
1. **回溯**：直接读取 `papers_metadata.json`，不需要联网、不重新抓取。
2. **增量**：只为"评分已失效"的记录重算，未失效的沿用历史结果。
   失效原因按判断优先级：
     ================ ============================================
     missing          历史记录里根本没有 evaluation
     config_changed   权重 / 外部增强 / LLM 配置与当前不一致
     content_changed  标题 / 作者 / 摘要 / 提交时间发生了变化
     recency_expired  评分日期不是今天（时效性维度需要刷新）
     ================ ============================================
3. **对比**：输出改动前后的分数、排名、维度平均分变化报告。
"""

from __future__ import annotations

import json
import os
import shutil
from datetime import date
from typing import Any, Dict, List, Optional, Tuple

from evaluator import PaperEvaluator, paper_content_hash

# 失效原因常量
STALE_MISSING = "missing"
STALE_CONFIG = "config_changed"
STALE_CONTENT = "content_changed"
STALE_RECENCY = "recency_expired"
STALE_FORCED = "forced"

REASON_LABELS: Dict[str, str] = {
    STALE_MISSING: "缺少历史评分",
    STALE_CONFIG: "权重/配置已变更",
    STALE_CONTENT: "论文内容已变更",
    STALE_RECENCY: "时效性需刷新（跨天）",
    STALE_FORCED: "强制执行",
}

DIM_LABELS: Dict[str, str] = {
    "title": "标题",
    "author": "作者",
    "abstract": "摘要",
    "recency": "时效",
    "topic": "主题",
    "venue": "场所",
    "institution": "机构",
}


# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

def _stored_evaluation(paper: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """取出历史记录中可用的 evaluation（无有效 final_score 时返回 None）。"""
    ev = paper.get("evaluation")
    if isinstance(ev, dict) and ev.get("final_score") is not None:
        return ev
    return None


def _config_matches(stored: Dict[str, Any], evaluator: PaperEvaluator) -> bool:
    """历史评分是否与当前评分配置同口径。

    新记录直接比对 config_key；旧记录没有指纹，则退回比对 weights
    （venue 是运行时动态加入的维度，不参与比对）。
    """
    key = stored.get("config_key")
    if key is not None:
        return key == evaluator.config_key

    legacy = stored.get("weights")
    if not isinstance(legacy, dict) or not legacy:
        return False
    current = dict(evaluator.heuristic.weights)
    legacy = {k: float(v) for k, v in legacy.items() if k != "venue"}
    if set(legacy) != set(current):
        return False
    return all(abs(legacy[k] - current[k]) < 5e-3 for k in current)


def staleness_reason(paper: Dict[str, Any],
                     evaluator: PaperEvaluator,
                     today: Optional[date] = None) -> Optional[str]:
    """判断历史评分是否失效；返回失效原因，未失效返回 None。"""
    stored = _stored_evaluation(paper)
    if stored is None:
        return STALE_MISSING

    if not _config_matches(stored, evaluator):
        return STALE_CONFIG

    stored_hash = stored.get("content_hash")
    if stored_hash and stored_hash != paper_content_hash(paper):
        return STALE_CONTENT

    stamp = (today or date.today()).isoformat()
    if stored.get("evaluated_on") != stamp:
        return STALE_RECENCY
    return None


def rank_scores(scores: Dict[int, float]) -> Dict[int, int]:
    """把 {索引: 分数} 转为 {索引: 名次}，分数相同时按索引稳定排序。"""
    ordered = sorted(scores.items(), key=lambda kv: (-kv[1], kv[0]))
    return {idx: pos for pos, (idx, _) in enumerate(ordered, 1)}


def spearman(rank_a: List[float], rank_b: List[float]) -> float:
    """无第三方依赖的 Spearman 秩相关系数。"""
    n = len(rank_a)
    if n < 2:
        return 1.0
    ma, mb = sum(rank_a) / n, sum(rank_b) / n
    cov = sum((a - ma) * (b - mb) for a, b in zip(rank_a, rank_b))
    va = sum((a - ma) ** 2 for a in rank_a) ** 0.5
    vb = sum((b - mb) ** 2 for b in rank_b) ** 0.5
    return cov / (va * vb) if va and vb else 1.0


def save_backup(path: str, suffix: str = ".backup.json") -> str:
    """把历史文件复制一份备份，返回备份路径。"""
    root, _ = os.path.splitext(path)
    backup = f"{root}{suffix}"
    shutil.copy2(path, backup)
    return backup


# ---------------------------------------------------------------------------
# 增量评价
# ---------------------------------------------------------------------------

def reevaluate_history(papers: List[Dict[str, Any]],
                       evaluator: PaperEvaluator,
                       force: bool = False,
                       today: Optional[date] = None) -> Dict[str, Any]:
    """回溯历史记录并按需增量重算评分。

    返回 ``{"stats", "before", "after"}``，其中 before/after 是与
    ``papers`` 等长的列表，元素为 ``None`` 或 ``{"score", "dims"}``。
    以列表下标（而非 url）作为键，避免 url 缺失或重复导致的覆盖。
    """
    today = today or date.today()
    stats: Dict[str, Any] = {
        "total": len(papers),
        "reevaluated": 0,
        "skipped": 0,
        "reasons": {},
        "missing_before": 0,
        "old_weight_sets": set(),
    }
    before: List[Optional[Dict[str, Any]]] = [None] * len(papers)
    after: List[Optional[Dict[str, Any]]] = [None] * len(papers)

    for i, paper in enumerate(papers):
        stored = _stored_evaluation(paper)
        if stored is not None:
            before[i] = {
                "score": float(stored["final_score"]),
                "dims": dict(stored.get("dimension_scores") or {}),
                "weights": dict(stored.get("weights") or {}),
            }
            old_w = stored.get("weights")
            if isinstance(old_w, dict) and old_w:
                stats["old_weight_sets"].add(
                    tuple(sorted((k, round(float(v), 3)) for k, v in old_w.items()))
                )
        else:
            stats["missing_before"] += 1

        reason = STALE_FORCED if force else staleness_reason(paper, evaluator, today)
        if reason is None:
            stats["skipped"] += 1
            after[i] = {"score": before[i]["score"], "dims": dict(before[i]["dims"])}
            continue

        stats["reasons"][reason] = stats["reasons"].get(reason, 0) + 1
        new_ev = evaluator.evaluate(paper, today=today)
        paper["evaluation"] = new_ev
        stats["reevaluated"] += 1
        after[i] = {
            "score": float(new_ev["final_score"]),
            "dims": dict(new_ev.get("dimension_scores") or {}),
        }

    return {"stats": stats, "before": before, "after": after}


# ---------------------------------------------------------------------------
# 前后对比
# ---------------------------------------------------------------------------

def compare_before_after(papers: List[Dict[str, Any]],
                         before: List[Optional[Dict[str, Any]]],
                         after: List[Optional[Dict[str, Any]]],
                         top_n: int = 10) -> Dict[str, Any]:
    """对比改动前后的评分效果。

    只在"前后都有评分"的论文（可对比集合）上统计，保证口径一致。
    """
    idx = [i for i in range(len(papers))
           if before[i] is not None and after[i] is not None]

    before_scores = {i: before[i]["score"] for i in idx}
    after_scores = {i: after[i]["score"] for i in idx}
    before_rank = rank_scores(before_scores)
    after_rank = rank_scores(after_scores)

    deltas = {i: after_scores[i] - before_scores[i] for i in idx}
    rank_deltas = {i: before_rank[i] - after_rank[i] for i in idx}  # >0 表示名次上升

    changed = [i for i in idx if abs(deltas[i]) > 1e-9]

    # ---- 维度平均分变化 ----
    dim_deltas: Dict[str, Tuple[float, float]] = {}
    dim_keys = set()
    for i in idx:
        dim_keys |= set(before[i]["dims"]) | set(after[i]["dims"])
    for dim in sorted(dim_keys):
        b_vals = [before[i]["dims"][dim] for i in idx
                  if before[i]["dims"].get(dim) is not None]
        a_vals = [after[i]["dims"][dim] for i in idx
                  if after[i]["dims"].get(dim) is not None]
        if b_vals and a_vals:
            dim_deltas[dim] = (sum(b_vals) / len(b_vals),
                               sum(a_vals) / len(a_vals))

    # ---- Top-N ----
    rank_by = lambda key: sorted(idx, key=lambda i: key[i])  # noqa: E731
    top_before = rank_by(before_rank)[:top_n]
    top_after = rank_by(after_rank)[:top_n]
    top_overlap = len(set(top_before) & set(top_after))

    # ---- 变化最大的论文 ----
    movers = sorted(idx, key=lambda i: deltas[i], reverse=True)

    def entry(i: int) -> Dict[str, Any]:
        return {
            "title": papers[i].get("title", ""),
            "url": papers[i].get("url", ""),
            "before_score": before_scores[i],
            "after_score": after_scores[i],
            "score_delta": deltas[i],
            "before_rank": before_rank[i],
            "after_rank": after_rank[i],
            "rank_delta": rank_deltas[i],
        }

    return {
        "comparable": len(idx),
        "changed": len(changed),
        "changed_ratio": (len(changed) / len(idx)) if idx else 0.0,
        "mean_delta": (sum(deltas.values()) / len(idx)) if idx else 0.0,
        "mean_abs_delta": (sum(abs(v) for v in deltas.values()) / len(idx)) if idx else 0.0,
        "max_up": entry(movers[0]) if movers else None,
        "max_down": entry(movers[-1]) if movers else None,
        "entries": [entry(i) for i in sorted(idx, key=lambda i: after_rank[i])],
        "top_n": top_n,
        "top_overlap": top_overlap,
        "top_before": [entry(i) for i in top_before],
        "top_after": [entry(i) for i in top_after],
        "spearman": spearman([before_rank[i] for i in idx],
                             [after_rank[i] for i in idx]),
        "movers_up": [entry(i) for i in
                      sorted(idx, key=lambda i: (-rank_deltas[i], deltas[i]))[:5]],
        "movers_down": [entry(i) for i in
                        sorted(idx, key=lambda i: (rank_deltas[i], -deltas[i]))[:5]],
        "dim_deltas": dim_deltas,
    }


# ---------------------------------------------------------------------------
# 报告渲染
# ---------------------------------------------------------------------------

def _fmt_weights(weights: Dict[str, float]) -> str:
    return " ".join(f"{k}={float(v):.3f}" for k, v in sorted(weights.items()))


def render_report(stats: Dict[str, Any],
                  comparison: Dict[str, Any],
                  evaluator: PaperEvaluator,
                  top_n: int = 10) -> str:
    """把统计与对比结果渲染成可读的文本报告。"""
    lines: List[str] = []
    add = lines.append

    add("=" * 72)
    add("历史回溯 · 增量评价 · 前后对比报告")
    add("=" * 72)
    add(f"生成日期            : {date.today().isoformat()}")
    add(f"历史记录总数        : {stats['total']}")
    add(f"本次重评            : {stats['reevaluated']}")
    add(f"沿用历史评分        : {stats['skipped']}")
    add(f"原本就无评分        : {stats['missing_before']}")
    reasons = stats["reasons"]
    if reasons:
        detail = "、".join(
            f"{REASON_LABELS.get(k, k)}×{v}" for k, v in sorted(reasons.items())
        )
        add(f"重评原因分布        : {detail}")

    add("")
    add("---- 评分口径 ----")
    old_sets = sorted(stats.get("old_weight_sets") or [])
    if old_sets:
        for w in old_sets:
            add(f"历史权重            : {_fmt_weights(dict(w))}")
    else:
        add("历史权重            : （历史记录未保存权重）")
    add(f"当前权重            : {_fmt_weights(evaluator.heuristic.weights)}")
    add(f"配置指纹            : {evaluator.config_key}")

    c = comparison
    add("")
    add("---- 可对比集合 ----")
    add(f"前后均有评分        : {c['comparable']}")
    if c["comparable"]:
        add(f"分数发生变化        : {c['changed']} "
            f"({c['changed_ratio'] * 100:.1f}%)")
        add(f"平均变化 / 平均绝对变化: {c['mean_delta']:+.2f} / {c['mean_abs_delta']:.2f}")

    if c["comparable"] and c["max_up"] and c["max_down"]:
        add("")
        add("---- 分数变化最大 ----")
        for label, item in (("上升最多", c["max_up"]), ("下降最多", c["max_down"])):
            add(f"{label}            : {item['score_delta']:+.2f} "
                f"({item['before_score']:.1f} -> {item['after_score']:.1f}) "
                f"{item['title'][:52]}")

    if c["comparable"]:
        add("")
        add("---- 排序稳定性 ----")
        add(f"Spearman 相关系数   : {c['spearman']:.4f}")
        add(f"Top-{c['top_n']:<3}重合数        : {c['top_overlap']}/{c['top_n']}")

        add("")
        add(f"---- 名次变动 Top-5（升 / 降）----")
        for label, items in (("上升", c["movers_up"]), ("下降", c["movers_down"])):
            add(f"  [{label}]")
            for it in items:
                add(f"    {it['rank_delta']:+3d} 位 "
                    f"({it['before_rank']:>3} -> {it['after_rank']:>3}) "
                    f"score {it['before_score']:5.1f} -> {it['after_score']:5.1f} | "
                    f"{it['title'][:46]}")

        add("")
        add("---- 维度平均分变化 ----")
        for dim, (b, a) in c["dim_deltas"].items():
            add(f"  {DIM_LABELS.get(dim, dim):<6} {b:.3f} -> {a:.3f}  ({a - b:+.3f})")

    add("")
    add(f"---- 新口径 Top-{top_n} ----")
    for pos, it in enumerate(c["top_after"], 1):
        add(f"  #{pos:02d} {it['after_score']:5.1f} | {it['title'][:60]}")
    add("=" * 72)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 一站式入口
# ---------------------------------------------------------------------------

def run(papers: List[Dict[str, Any]],
        evaluator: PaperEvaluator,
        force: bool = False,
        top_n: int = 10,
        today: Optional[date] = None) -> Dict[str, Any]:
    """回溯 + 增量重评 + 对比，返回统计、对比结果与文本报告。"""
    result = reevaluate_history(papers, evaluator, force=force, today=today)
    stats = result["stats"]
    comparison = compare_before_after(
        papers, result["before"], result["after"], top_n=top_n
    )
    report = render_report(stats, comparison, evaluator, top_n=top_n)
    stats["old_weight_sets"] = sorted(stats["old_weight_sets"])
    return {"stats": stats, "comparison": comparison, "report": report}


if __name__ == "__main__":
    path = "papers_metadata.json"
    if not os.path.exists(path):
        print(f"{path} not found.")
        raise SystemExit(1)

    with open(path, "r", encoding="utf-8") as f:
        _papers = json.load(f)

    print(run(_papers, PaperEvaluator(), force=True)["report"])
