"""test_keywords.py - 用 AI 领域热门关键词对整条流水线做端到端测试。

运行：
    python test_keywords.py                # 跑 10 个内置热门关键词
    python test_keywords.py --delay 0      # 不做请求间隔（arXiv 可能限流）
    python test_keywords.py --save out.json
    python test_keywords.py --keywords "agent" "diffusion"

与 test_weights.py / test_history.py 的区别：那两者是**离线单元测试**，
本脚本会真实访问 arXiv，验证 retriever 抓取 + evaluator 评分在**不同主题**
下都稳定可用，并且 topic 维度确实对热点关键词有响应。

脚本只读不写：结果保存在内存中，不会污染 papers_metadata.json。
"""

import argparse
import json
import os

import time
from typing import Any, Dict, List, Optional, Tuple

from evaluator import PaperEvaluator, TOPIC_KEYWORDS, kw_match
from retriever import Retriever

# AI 研究当前热门关键词（覆盖基础模型 / Agent / 检索 / 推理 / 多模态 /
# 生成 / 安全 / 效率 / 强化学习 / 推理时扩展 十个方向）
HOT_KEYWORDS: List[str] = [
    "large language model",
    "agent",
    "retrieval-augmented generation",
    "chain-of-thought",
    "multimodal",
    "diffusion",
    "LLM safety",
    "quantization",
    "reinforcement learning",
    "test-time scaling",
]

# 对照组：与上述热点无关的领域，用来验证 topic 打分的区分度
CONTROL_KEYWORD = "geology"

# 抓取结果中必须齐全的字段
REQUIRED_FIELDS = ("title", "authors", "url", "abstract", "submission_time")

failures: List[str] = []
warnings: List[str] = []


def check(condition: bool, message: str) -> None:
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {message}")
    if not condition:
        failures.append(message)


def note(condition: bool, message: str) -> None:
    """仅提示，不计入失败。"""
    status = "PASS" if condition else "WARN"
    print(f"  [{status}] {message}")
    if not condition:
        warnings.append(message)


# ---------------------------------------------------------------------------
# 统计工具
# ---------------------------------------------------------------------------

def mean(values: List[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def stdev(values: List[float]) -> float:
    if len(values) < 2:
        return 0.0
    m = mean(values)
    return (sum((v - m) ** 2 for v in values) / len(values)) ** 0.5


def dimension_means(papers: List[Dict[str, Any]],
                    dims: List[str]) -> Dict[str, float]:
    out: Dict[str, float] = {}
    for dim in dims:
        vals = [p["evaluation"]["dimension_scores"][dim] for p in papers
                if p.get("evaluation", {}).get("dimension_scores", {}).get(dim) is not None]
        out[dim] = mean(vals)
    return out


def field_completeness(papers: List[Dict[str, Any]]) -> Dict[str, float]:
    """各字段非 N/A 的比例，用于检查 retriever 的解析健壮性。"""
    if not papers:
        return {f: 0.0 for f in REQUIRED_FIELDS}
    out = {}
    for f in REQUIRED_FIELDS:
        ok = sum(1 for p in papers
                 if p.get(f) and str(p.get(f)).strip() not in ("", "N/A"))
        out[f] = ok / len(papers)
    return out


def topic_keyword_hits(papers: List[Dict[str, Any]]) -> Tuple[float, List[str]]:
    """有多少比例的论文至少命中一个 TOPIC_KEYWORDS 条目；同时返回命中的词表。

    复用 evaluator.kw_match，保证与 topic 打分的判定口径完全一致。
    """
    if not papers:
        return 0.0, []
    hit_words: Dict[str, int] = {}
    hit_docs = 0
    for p in papers:
        text = f"{p.get('title', '')} {p.get('abstract', '')}".lower()
        words = [kw for kw in TOPIC_KEYWORDS if kw_match(kw, text)]
        if words:
            hit_docs += 1
        for w in words:
            hit_words[w] = hit_words.get(w, 0) + 1
    top_words = [w for w, _ in sorted(hit_words.items(),
                                      key=lambda kv: -kv[1])[:8]]
    return hit_docs / len(papers), top_words


# ---------------------------------------------------------------------------
# 单关键词测试
# ---------------------------------------------------------------------------

def probe(keyword: str, retriever: Retriever,
          evaluator: PaperEvaluator) -> Dict[str, Any]:
    """抓取 + 评分一个关键词，返回统计结果。"""
    print(f"\n>>> 关键词: {keyword!r}")
    started = time.time()
    try:
        papers = retriever.fetch_papers(keyword)
    except Exception as exc:  # noqa: BLE001
        print(f"    抓取异常: {exc}")
        papers = []
    elapsed = time.time() - started

    ranked = evaluator.rank(papers) if papers else []
    scores = [s for s, _ in ranked]
    dims = ["title", "author", "abstract", "recency", "topic"]
    dim_means = dimension_means(papers, dims) if papers else {d: 0.0 for d in dims}
    hit_ratio, top_words = topic_keyword_hits(papers)

    return {
        "keyword": keyword,
        "count": len(papers),
        "elapsed": round(elapsed, 2),
        "scores": scores,
        "score_mean": round(mean(scores), 2),
        "score_std": round(stdev(scores), 2),
        "score_min": round(min(scores), 2) if scores else 0.0,
        "score_max": round(max(scores), 2) if scores else 0.0,
        "dim_means": {k: round(v, 3) for k, v in dim_means.items()},
        "completeness": {k: round(v, 3)
                         for k, v in field_completeness(papers).items()},
        "topic_hit_ratio": round(hit_ratio, 3),
        "topic_words": top_words,
        "top3": [
            {
                "score": s,
                "title": p.get("title", ""),
                "url": p.get("url", ""),
                "submission_time": p.get("submission_time", ""),
            }
            for s, p in ranked[:3]
        ],
        # 原始抓取结果，仅内存使用，不写入 JSON
        "_papers": papers,
    }


# ---------------------------------------------------------------------------
# 报告
# ---------------------------------------------------------------------------

def render(results: List[Dict[str, Any]], control: Dict[str, Any],
           evaluator: PaperEvaluator, top_n: int = 3) -> str:
    lines: List[str] = []
    add = lines.append
    W = 96

    add("=" * W)
    add("AI 热门关键词 · 端到端流水线测试报告")
    add("=" * W)
    add(f"关键词数量          : {len(results)}")
    add(f"评分配置指纹        : {evaluator.config_key}")
    add(f"权重                : " + " ".join(
        f"{k}={v:.3f}" for k, v in sorted(evaluator.heuristic.weights.items())))

    total = sum(r["count"] for r in results)
    add(f"抓取论文总数        : {total}")

    add("")
    add("---- 逐关键词概览 ----")
    header = (f"{'关键词':<30} {'条数':>5} {'均分':>7} {'标准差':>7} "
              f"{'主题':>6} {'命中率':>7} {'摘要完整':>8} {'耗时':>6}")
    add(header)
    add("-" * W)
    for r in results:
        add(f"{r['keyword']:<30} {r['count']:>5} "
            f"{r['score_mean']:>7.2f} {r['score_std']:>7.2f} "
            f"{r['dim_means']['topic']:>6.3f} {r['topic_hit_ratio']:>7.1%} "
            f"{r['completeness']['abstract']:>8.1%} {r['elapsed']:>5.1f}s")

    add("")
    add("---- 维度均分（按关键词）----")
    dims = ["title", "author", "abstract", "recency", "topic"]
    add(f"{'关键词':<30} " + " ".join(f"{d:>8}" for d in dims))
    add("-" * W)
    for r in results:
        add(f"{r['keyword']:<30} " +
            " ".join(f"{r['dim_means'][d]:>8.3f}" for d in dims))
    add("-" * W)
    add(f"{'[均值]':<30} " + " ".join(
        f"{mean([r['dim_means'][d] for r in results]):>8.3f}" for d in dims))
    add(f"{'[对照组 ' + control['keyword'] + ']':<30} " + " ".join(
        f"{control['dim_means'][d]:>8.3f}" for d in dims))

    add("")
    add("---- 主题（topic）维度区分度 ----")
    hot_topic = mean([r["dim_means"]["topic"] for r in results])
    ctrl_topic = control["dim_means"]["topic"]
    add(f"热点关键词 topic 均分: {hot_topic:.3f}")
    add(f"对照关键词 topic 均分: {ctrl_topic:.3f}  ({control['keyword']!r})")
    add(f"差值                : {hot_topic - ctrl_topic:+.3f}")

    add("")
    add("---- 每个关键词命中的热点词（Top-8）----")
    for r in results:
        words = "、".join(r["topic_words"][:8]) or "（无）"
        add(f"  {r['keyword']:<30} {words}")

    add("")
    add(f"---- 各关键词评分 Top-{top_n} ----")
    for r in results:
        add(f"  [{r['keyword']}]")
        if not r["top3"]:
            add("    （无结果）")
            continue
        for i, t in enumerate(r["top3"], 1):
            add(f"    #{i} {t['score']:5.1f} [{t['submission_time']}] "
                f"{t['title'][:64]}")

    add("=" * W)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="AI 热门关键词端到端测试")
    parser.add_argument("--keywords", nargs="*", default=None,
                        help="自定义关键词；默认使用内置 10 个热门关键词")
    parser.add_argument("--delay", type=float, default=2.0,
                        help="两次 arXiv 请求之间的间隔秒数（默认 2.0）")
    parser.add_argument("--control", default=CONTROL_KEYWORD,
                        help=f"对照组关键词（默认 {CONTROL_KEYWORD!r}）")
    parser.add_argument("--save", default=None,
                        help="把原始统计结果写入 JSON 文件")
    parser.add_argument("--top", type=int, default=3,
                        help="每个关键词展示的 Top-N（默认 3）")
    args = parser.parse_args()

    keywords = args.keywords if args.keywords else HOT_KEYWORDS
    retriever = Retriever()
    evaluator = PaperEvaluator()

    print("=" * 96)
    print(f"开始测试 {len(keywords)} 个关键词" + (f" + 对照组 {args.control!r}" if args.control else ""))
    print("=" * 96)

    results: List[Dict[str, Any]] = []

    print("\n【第 1 部分】抓取与评分")
    for i, kw in enumerate(keywords):
        if i and args.delay > 0:
            time.sleep(args.delay)  # 对 arXiv 友好一些
        results.append(probe(kw, retriever, evaluator))

    # 对照组
    if args.control:
        if args.delay > 0:
            time.sleep(args.delay)
        print("\n【对照组】")
        control = probe(args.control, retriever, evaluator)
    else:
        control = {"keyword": "(未启用)", "count": 0, "elapsed": 0.0,
                   "dim_means": {d: 0.0 for d in
                                 ["title", "author", "abstract", "recency", "topic"]},
                   "completeness": {}, "topic_hit_ratio": 0.0,
                   "topic_words": [], "top3": [], "scores": [],
                   "score_mean": 0.0, "score_std": 0.0,
                   "score_min": 0.0, "score_max": 0.0, "_papers": []}

    report = render(results, control, evaluator, top_n=args.top)
    print("\n\n【第 2 部分】测试报告")
    print(report)

    # ---- 断言 ----
    print("\n【第 3 部分】校验")
    print("\nA) 抓取可用性")
    empty = [r["keyword"] for r in results if r["count"] == 0]
    check(not empty, f"所有关键词都抓到了论文（失败: {empty or '无'}）")
    low = [r["keyword"] for r in results if 0 < r["count"] < 10]
    note(not low, f"每个关键词至少 10 条结果（偏少: {low or '无'}）")

    print("\nB) 字段解析完整性")
    for f in REQUIRED_FIELDS:
        worst = min((r["completeness"].get(f, 0.0), r["keyword"]) for r in results)
        check(worst[0] >= 0.9,
              f"{f} 完整率 >= 90%（最低 {worst[0]:.1%} @ {worst[1]!r}）")

    print("\nC) 评分合法性")
    bad_range = [(r["keyword"], s) for r in results for s in r["scores"]
                 if not (0.0 <= s <= 100.0)]
    check(not bad_range, f"综合分全部落在 [0, 100]（越界 {len(bad_range)} 个）")
    bad_dim = []
    for r in results:
        for d, v in r["dim_means"].items():
            if not (0.0 <= v <= 1.0):
                bad_dim.append((r["keyword"], d, v))
    check(not bad_dim, f"维度均分全部落在 [0, 1]（越界 {len(bad_dim)} 个）")

    print("\nD) 排序区分度")
    flat = [r["keyword"] for r in results if r["count"] > 1 and r["score_std"] < 1.0]
    check(not flat, f"每个关键词的评分都有区分度（std < 1.0 的: {flat or '无'}）")
    all_same = [r["keyword"] for r in results
                if r["count"] > 1 and r["score_min"] == r["score_max"]]
    check(not all_same, f"没有出现全部同分（{all_same or '无'}）")

    print("\nE) topic 维度对热点关键词的响应")
    ctrl_topic = control["dim_means"]["topic"]
    if args.control:
        # topic_score = 1 - exp(-sum(w)/2)，只命中单个热点词时天然只有 0.2~0.4，
        # 所以不设统一高分阈值，改看两个更本质的性质：
        #   (1) 每个热点关键词都要明显高于对照组；
        #   (2) 话题命中率不能太低。
        for r in results:
            check(r["dim_means"]["topic"] > ctrl_topic,
                  f"{r['keyword']!r} topic 均分 ({r['dim_means']['topic']:.3f}) "
                  f"> 对照组 ({ctrl_topic:.3f})")
        hot_topic = mean([r["dim_means"]["topic"] for r in results])
        check(hot_topic > ctrl_topic,
              f"热点关键词 topic 均分 ({hot_topic:.3f}) > 对照组 {control['keyword']!r} "
              f"({ctrl_topic:.3f})")
    else:
        note(False, "未启用对照组，跳过 topic 区分度对比")

    low_hit = [(r["keyword"], r["topic_hit_ratio"]) for r in results
               if r["topic_hit_ratio"] < 0.5]
    check(not low_hit,
          f"每个关键词至少一半论文命中热点词表（偏低: {low_hit or '无'}）")
    for r in results:
        check(r["dim_means"]["topic"] > 0.2,
              f"{r['keyword']!r} topic 均分有实质信号 > 0.2"
              f"（实际 {r['dim_means']['topic']:.3f}）")

    print("\nF) 与增量评价联动")
    from history import reevaluate_history
    # 模拟"历史记录"：剥掉 probe() 刚写入的评分，得到一条纯抓取结果
    stripped = [{k: v for k, v in p.items() if k != "evaluation"}
                for p in (results[0]["_papers"] if results else [])]
    if stripped:
        ev = PaperEvaluator()
        first = reevaluate_history(stripped, ev)
        check(first["stats"]["reevaluated"] == len(stripped),
              f"无历史评分时全部重算（{first['stats']['reevaluated']}/{len(stripped)}）")
        check(first["stats"]["reasons"].get("missing") == len(stripped),
              "重评原因全部为 missing")
        second = reevaluate_history(stripped, ev)
        check(second["stats"]["reevaluated"] == 0,
              f"同配置同日期重跑 0 条重算（沿用 {second['stats']['skipped']}）")
        check(all(0.0 <= x["score"] <= 100.0 for x in second["after"]),
              "沿用/重评的分数都在合法区间")
    else:
        note(False, "首个关键词无结果，跳过增量联动校验")

    if args.save:
        payload = {"evaluator_config_key": evaluator.config_key,
                   "weights": evaluator.heuristic.weights,
                   "results": [{k: v for k, v in r.items() if k != "_papers"}
                               for r in results],
                   "control": {k: v for k, v in control.items() if k != "_papers"}}
        with open(args.save, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2, ensure_ascii=False)
        print(f"\n原始结果已保存到 {args.save}")
        check(os.path.exists(args.save), f"结果文件已生成（{args.save}）")

    print("\n" + "=" * 96)
    if warnings:
        print(f"WARN: {len(warnings)} 项提示")
        for w in warnings:
            print(f"  - {w}")
    if failures:
        print(f"FAILED: {len(failures)} 项检查未通过")
        for m in failures:
            print(f"  - {m}")
        return 1
    print("ALL CHECKS PASSED")
    print("=" * 96)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
