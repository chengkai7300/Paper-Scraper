"""test_weights.py - 验证 abstract 权重下调后的评估行为。

运行：python test_weights.py
覆盖点：
  1. 权重的归一化与合法性（非负、和为 1、abstract 已下调）；
  2. 所有维度分值与综合分落在合法区间 [0, 100]；
  3. 与旧权重（abstract=0.30）对比排序差异，确认改动生效且未破坏排序稳定性。
"""

import json
import os
from typing import Dict, List, Tuple

from evaluator import HeuristicEvaluator, PaperEvaluator
from history import rank_scores, spearman

OLD_WEIGHTS: Dict[str, float] = {
    "title": 0.15,
    "author": 0.15,
    "abstract": 0.30,
    "recency": 0.10,
    "topic": 0.30,
}

METADATA_FILE = "papers_metadata.json"
failures: List[str] = []


def check(condition: bool, message: str) -> None:
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {message}")
    if not condition:
        failures.append(message)


def load_papers() -> List[dict]:
    if not os.path.exists(METADATA_FILE):
        raise SystemExit(f"{METADATA_FILE} not found; run `python main.py` first.")
    with open(METADATA_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def main() -> int:
    papers = load_papers()
    print(f"Loaded {len(papers)} papers from {METADATA_FILE}\n")

    # ---- 1. 权重合法性 ----
    print("1) 权重配置")
    new_weights = HeuristicEvaluator().weights
    check(abs(sum(new_weights.values()) - 1.0) < 1e-9,
          f"新权重归一化后和为 1.0（实际 {sum(new_weights.values()):.6f}）")
    check(all(w >= 0 for w in new_weights.values()), "所有维度权重非负")

    old_norm = {k: v / sum(OLD_WEIGHTS.values()) for k, v in OLD_WEIGHTS.items()}
    check(new_weights["abstract"] == 0.15,
          f"abstract 权重 = {new_weights['abstract']:.3f}（目标 0.15）")
    check(new_weights["abstract"] < old_norm["abstract"],
          f"abstract 权重已下调：{old_norm['abstract']:.3f} -> {new_weights['abstract']:.3f}")
    for dim in ("title", "author", "recency"):
        check(new_weights[dim] > old_norm[dim],
              f"{dim} 权重回补：{old_norm[dim]:.3f} -> {new_weights[dim]:.3f}")
    check(new_weights["topic"] == old_norm["topic"], "topic 权重保持不变（0.300）")
    print(f"  权重明细: { {k: round(v, 4) for k, v in new_weights.items()} }\n")

    # ---- 2. 分值区间 ----
    print("2) 分值与区间")
    new_eval = PaperEvaluator()
    new_ranked: List[Tuple[float, dict]] = new_eval.rank(papers)
    scores = [s for s, _ in new_ranked]
    check(all(0.0 <= s <= 100.0 for s in scores),
          f"综合分全部落在 [0, 100]（min={min(scores):.2f}, max={max(scores):.2f}）")
    check(all(s == s for s in scores), "综合分无 NaN")

    bad_dims = []
    for _, p in new_ranked:
        for k, v in p["evaluation"]["dimension_scores"].items():
            if v is None or not (0.0 <= v <= 1.0):
                bad_dims.append((p["title"][:40], k, v))
    check(not bad_dims, f"所有维度分值落在 [0, 1]（异常 {len(bad_dims)} 处）")

    # ---- 3. 改动生效性 ----
    print("\n3) 新旧权重对比")
    old_eval = PaperEvaluator(weights=dict(OLD_WEIGHTS))
    old_ranked = old_eval.rank([dict(p) for p in papers])
    old_scores = [s for s, _ in old_ranked]

    # rank() 返回的是按分数排序后的列表，需要还原到原始论文顺序再比较
    new_by_url = {p["url"]: s for s, p in new_ranked}
    old_by_url = {p["url"]: s for s, p in old_ranked}
    keys = [p["url"] for p in papers]
    ns = [new_by_url[k] for k in keys]
    os_ = [old_by_url[k] for k in keys]

    changed = sum(1 for a, b in zip(ns, os_) if abs(a - b) > 1e-6)
    print(f"  综合分发生变化的论文: {changed}/{len(keys)}")
    check(changed > 0, "abstract 权重下调确实改变了综合分")

    new_rank = rank_scores({i: s for i, s in enumerate(ns)})
    old_rank = rank_scores({i: s for i, s in enumerate(os_)})
    rho = spearman([new_rank[i] for i in range(len(keys))],
                   [old_rank[i] for i in range(len(keys))])
    print(f"  新旧排序 Spearman 相关系数: {rho:.4f}")
    check(rho > 0.5, "新旧排序整体一致性良好（rho > 0.5），未出现排序崩塌")

    top_new = {p["url"] for _, p in new_ranked[:10]}
    top_old = {p["url"] for _, p in old_ranked[:10]}
    print(f"  Top-10 重合数: {len(top_new & top_old)}/10（排名变化属预期）")

    # abstract 维度自身的区分度对比：分值标准差越小说明该维度越"平"
    abs_new = [p["evaluation"]["dimension_scores"]["abstract"] for _, p in new_ranked]
    mean = sum(abs_new) / len(abs_new)
    std = (sum((x - mean) ** 2 for x in abs_new) / len(abs_new)) ** 0.5
    print(f"  abstract 维度: mean={mean:.3f}, std={std:.3f}（std 偏小说明区分度低，支持降权）")

    print(f"\n  ---- 新权重 Top-10 ----")
    for i, (s, p) in enumerate(new_ranked[:10], 1):
        d = p["evaluation"]["dimension_scores"]
        print(f"  #{i:02d} {s:5.1f} | Ab={d['abstract']:.2f} Tp={d['topic']:.2f} "
              f"T={d['title']:.2f} | {p['title'][:64]}")

    print("\n" + ("=" * 60))
    if failures:
        print(f"FAILED: {len(failures)} 项检查未通过")
        for m in failures:
            print(f"  - {m}")
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
