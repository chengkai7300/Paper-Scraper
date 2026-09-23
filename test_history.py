"""test_history.py - 历史回溯 / 增量评价 / 前后对比 的回归测试。

运行：python test_history.py
覆盖点：
  1. staleness_reason 的五种判断路径（缺失 / 配置变更 / 内容变更 / 跨天 / 新鲜）
  2. 增量语义：同配置同日期重跑应全部跳过；跨天应全部按 recency 重算；force 强制全算
  3. 重评幂等性：连续两次 run 的分数完全一致
  4. 对比指标正确性：Spearman、Top-N 重合、维度平均分不受权重影响
  5. 端到端：在真实 papers_metadata.json 上跑全流程并生成报告
"""

import json
import os
import shutil
import tempfile
from datetime import date, timedelta
from typing import Any, Dict, List

import history
from evaluator import (
    HeuristicEvaluator,
    PaperEvaluator,
    paper_content_hash,
)

METADATA_FILE = "papers_metadata.json"
TODAY = date(2026, 9, 16)
failures: List[str] = []

# 旧权重（abstract=0.30），用于构造"配置已变更"的历史记录
OLD_WEIGHTS = {
    "title": 0.15, "author": 0.15, "abstract": 0.30,
    "recency": 0.10, "topic": 0.30,
}


def check(condition: bool, message: str) -> None:
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {message}")
    if not condition:
        failures.append(message)


def make_paper(title: str = "A Test Paper", abstract: str = "x" * 700) -> Dict[str, Any]:
    return {
        "title": title,
        "authors": "Alice, Bob",
        "url": f"https://arxiv.org/abs/2609.00001",
        "abstract": abstract,
        "submission_time": "2026-09-10",
    }


_UNSET = object()


def stored_evaluation(paper: Dict[str, Any], evaluator: PaperEvaluator,
                      weights: Dict[str, float] = None,
                      evaluated_on: Any = _UNSET,
                      config_key: Any = _UNSET,
                      content_hash: Any = _UNSET) -> Dict[str, Any]:
    """构造一条"历史记录"：用 evaluator 评分后，按需覆写溯源字段。

    只有显式传入的参数才会被覆写；传 None 即写入 None（模拟旧记录）。
    """
    ev = evaluator.evaluate(paper)
    if weights is not None:
        ev["weights"] = dict(weights)
    if evaluated_on is not _UNSET:
        ev["evaluated_on"] = evaluated_on
    if config_key is not _UNSET:
        ev["config_key"] = config_key
    if content_hash is not _UNSET:
        ev["content_hash"] = content_hash
    paper["evaluation"] = ev
    return paper


# ---------------------------------------------------------------------------

def test_staleness() -> None:
    print("\n1) staleness_reason 判断路径")
    ev = PaperEvaluator()

    # 1.1 无历史评分
    check(history.staleness_reason(make_paper(), ev, TODAY) == history.STALE_MISSING,
          "无 evaluation -> missing")

    # 1.2 旧权重且无指纹（真实历史记录的形态）-> 配置变更
    p = stored_evaluation(make_paper(), ev, weights=OLD_WEIGHTS,
                          config_key=None, evaluated_on=None)
    check(history.staleness_reason(p, ev, TODAY) == history.STALE_CONFIG,
          "旧权重(abstract=0.30)且无指纹 -> config_changed")

    # 1.3 权重一致、仅缺指纹 -> 视为同口径，继续看日期
    p = make_paper()
    p = stored_evaluation(p, ev, weights=ev.heuristic.weights,
                          config_key=None, evaluated_on=TODAY.isoformat())
    check(history.staleness_reason(p, ev, TODAY) is None,
          "旧记录权重一致且日期为今天 -> 不重算")

    # 1.4 指纹不匹配 -> 配置变更
    p = stored_evaluation(make_paper(), ev, config_key="deadbeef0000",
                          evaluated_on=TODAY.isoformat())
    check(history.staleness_reason(p, ev, TODAY) == history.STALE_CONFIG,
          "config_key 不匹配 -> config_changed")

    # 1.5 内容变更
    p = make_paper()
    stored_evaluation(p, ev, evaluated_on=TODAY.isoformat())
    p["abstract"] += " 新增内容"
    check(history.staleness_reason(p, ev, TODAY) == history.STALE_CONTENT,
          "摘要变化 -> content_changed")

    # 1.6 跨天 -> 时效性刷新
    p = stored_evaluation(make_paper(), ev,
                          evaluated_on=(TODAY - timedelta(days=1)).isoformat())
    check(history.staleness_reason(p, ev, TODAY) == history.STALE_RECENCY,
          "评分日期非今天 -> recency_expired")

    # 1.7 完全新鲜 -> 无需重算
    p = stored_evaluation(make_paper(), ev, evaluated_on=TODAY.isoformat())
    check(history.staleness_reason(p, ev, TODAY) is None,
          "配置/内容/日期都一致 -> 不重算")

    # 1.8 内容指纹本身的性质
    a, b_, c = make_paper(title="T1"), make_paper(title="T1"), make_paper(title="T2")
    check(paper_content_hash(a) == paper_content_hash(b_), "相同内容 -> 相同指纹")
    check(paper_content_hash(a) != paper_content_hash(c), "不同内容 -> 不同指纹")


def test_incremental() -> None:
    print("\n2) 增量语义")
    ev = PaperEvaluator()
    papers = [make_paper(title=f"P{i}") for i in range(5)]

    # 2.1 首次：全部缺失 -> 全部重算
    r1 = history.reevaluate_history(papers, ev, today=TODAY)
    check(r1["stats"]["reevaluated"] == 5, "首次运行重算 5 条（全部 missing）")
    check(r1["stats"]["reasons"].get(history.STALE_MISSING) == 5,
          "原因全部为 missing")

    # 2.2 同配置同日期再跑：应全部跳过（这是"增量"的核心）
    r2 = history.reevaluate_history(papers, ev, today=TODAY)
    check(r2["stats"]["reevaluated"] == 0 and r2["stats"]["skipped"] == 5,
          "同配置同日期重跑：0 条重算 / 5 条沿用")

    # 2.3 跨天：全部按 recency 刷新
    r3 = history.reevaluate_history(papers, ev, today=TODAY + timedelta(days=1))
    check(r3["stats"]["reasons"].get(history.STALE_RECENCY) == 5,
          "跨天重跑：5 条按 recency_expired 重算")

    # 2.4 权重变更：全部按配置变更刷新
    ev_new = PaperEvaluator(weights={"title": 0.4, "author": 0.1,
                                     "abstract": 0.2, "recency": 0.1,
                                     "topic": 0.2})
    r4 = history.reevaluate_history(papers, ev_new, today=TODAY)
    check(r4["stats"]["reasons"].get(history.STALE_CONFIG) == 5,
          "换权重重跑：5 条按 config_changed 重算")

    # 2.5 force：忽略增量判断
    r5 = history.reevaluate_history(papers, ev_new, force=True, today=TODAY)
    check(r5["stats"]["reevaluated"] == 5
          and r5["stats"]["reasons"].get(history.STALE_FORCED) == 5,
          "force=True：5 条全部强制重算")

    # 2.6 幂等性：连续两次结果完全一致
    a = history.reevaluate_history(papers, ev_new, force=True, today=TODAY)
    b = history.reevaluate_history(papers, ev_new, force=True, today=TODAY)
    check([x["score"] for x in a["after"]] == [x["score"] for x in b["after"]],
          "重评幂等：连续两次分数完全一致")


def test_comparison() -> None:
    print("\n3) 前后对比指标（合成数据，精确校验）")
    papers = [{"title": f"P{i}", "url": f"u{i}"} for i in range(4)]
    # before 分数: P0=90 P1=80 P2=70 P3=60  -> 名次 1,2,3,4
    # after  分数: P0=85 P1=95 P2=99 P3=70  -> 名次 3,2,1,4
    before = [{"score": s, "dims": {"title": 0.5, "abstract": 1.0}}
              for s in (90.0, 80.0, 70.0, 60.0)]
    after = [{"score": s, "dims": {"title": 0.5, "abstract": 1.0}}
             for s in (85.0, 95.0, 99.0, 70.0)]

    c = history.compare_before_after(papers, before, after, top_n=2)

    check(c["comparable"] == 4 and c["changed"] == 4, "可对比 4 条且全部变化")
    check(abs(c["mean_delta"] - 12.25) < 1e-9,
          f"平均变化 = +12.25（实际 {c['mean_delta']:+.2f}）")
    # |−5| + |+15| + |+29| + |+10| = 59, /4 = 14.75
    check(abs(c["mean_abs_delta"] - 14.75) < 1e-9,
          f"平均绝对变化 = 14.75（实际 {c['mean_abs_delta']:.2f}）")

    # 名次: P0 1->3, P1 2->2, P2 3->1, P3 4->4
    check(c["max_up"]["title"] == "P2" and abs(c["max_up"]["score_delta"] - 29.0) < 1e-9,
          "上升最多 = P2 (+29.0)")
    check(c["max_down"]["title"] == "P0" and abs(c["max_down"]["score_delta"] + 5.0) < 1e-9,
          "下降最多 = P0 (-5.0)")
    check(c["top_overlap"] == 1,
          f"Top-2 重合数 = 1（P0 掉出、P2 进入，实际 {c['top_overlap']}）")
    check(abs(c["spearman"] - 0.2) < 1e-9,
          f"Spearman = 0.2（实际 {c['spearman']:.4f}）")

    rank_deltas = {it["title"]: it["rank_delta"] for it in c["top_before"]}
    check(rank_deltas == {"P0": -2, "P1": 0}, f"名次变动正确（{rank_deltas}）")
    check(all(abs(a - b) < 1e-9 for b, a in c["dim_deltas"].values()),
          "维度平均分不受权重影响（只有综合分变化）")

    # 名次是 1..n 的置换，全部名次变动之和必须为 0
    total = sum(it["rank_delta"] for it in c["entries"])
    check(total == 0, f"全部名次变动之和为 0（实际 {total}）")
    check(len(c["entries"]) == 4, "entries 覆盖全部可对比论文")

    # 空输入不应报错
    empty = history.compare_before_after([], [], [])
    check(empty["comparable"] == 0 and empty["top_overlap"] == 0, "空输入不报错")

    # 报告结构
    report = history.render_report({"total": 4, "reevaluated": 4, "skipped": 0,
                                    "missing_before": 0, "reasons": {}},
                                   c, PaperEvaluator(), top_n=2)
    for section in ("历史回溯", "评分口径", "排序稳定性", "维度平均分变化"):
        check(section in report, f"报告包含「{section}」小节")


def test_comparison_real_data() -> None:
    print("\n4) 前后对比指标（真实历史记录 + 真实新旧权重）")
    old_ev = PaperEvaluator(weights=OLD_WEIGHTS)
    new_ev = PaperEvaluator()

    if not os.path.exists(METADATA_FILE):
        check(False, f"{METADATA_FILE} 不存在")
        return
    with open(METADATA_FILE, "r", encoding="utf-8") as f:
        papers = json.load(f)

    history.reevaluate_history(papers, old_ev, force=True, today=TODAY)
    r = history.reevaluate_history(papers, new_ev, force=True, today=TODAY)
    c = history.compare_before_after(papers, r["before"], r["after"], top_n=10)

    print(f"  可对比 {c['comparable']} 条，变化 {c['changed']} 条，"
          f"rho={c['spearman']:.4f}，Top-10 重合 {c['top_overlap']}/10")
    # 上一步已用旧权重为全部记录补了一份"改前"基线，故 150 条都可对比
    check(c["comparable"] == len(papers),
          f"补完基线后 {len(papers)} 条全部可对比（实际 {c['comparable']}）")
    check(c["changed"] > 0, f"权重下调引起 {c['changed']} 条分数变化")
    check(-1.0 <= c["spearman"] <= 1.0, f"Spearman 合法（{c['spearman']:.4f}）")
    check(0 < c["top_overlap"] <= 10, f"Top-10 仍有重合（{c['top_overlap']}/10）")

    total = sum(it["rank_delta"] for it in c["entries"])
    check(total == 0, f"全部名次变动之和为 0（实际 {total}）")

    # 维度原始分与权重无关，只有综合分变
    same = all(abs(a - b) < 1e-9 for b, a in c["dim_deltas"].values())
    check(same, "维度平均分不受权重影响（只有综合分变化）")


def test_backup() -> None:
    print("\n5) 备份")
    tmp = tempfile.mkdtemp()
    try:
        path = os.path.join(tmp, "meta.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"hello": "world"}, f)
        backup = history.save_backup(path)
        check(backup.endswith(".backup.json") and os.path.exists(backup),
              f"备份文件已生成（{os.path.basename(backup)}）")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_end_to_end() -> None:
    print("\n6) 真实数据端到端")
    if not os.path.exists(METADATA_FILE):
        check(False, f"{METADATA_FILE} 不存在")
        return
    with open(METADATA_FILE, "r", encoding="utf-8") as f:
        papers = json.load(f)

    result = history.run(papers, PaperEvaluator(), top_n=10)
    stats, c = result["stats"], result["comparison"]
    print(f"  记录 {stats['total']} 条，重评 {stats['reevaluated']} 条，"
          f"可对比 {c['comparable']} 条，rho={c['spearman']:.4f}")

    check(stats["total"] == len(papers), "统计总数与记录数一致")
    check(stats["reevaluated"] + stats["skipped"] == len(papers),
          "重评 + 沿用 == 总数")
    check(c["comparable"] > 0, "存在可对比论文")
    check("Top-10" in result["report"], "报告包含 Top-10 小节")

    # 回溯模式不应该破坏原始内容字段
    fields_ok = all(
        isinstance(p.get("title"), str) and isinstance(p.get("abstract"), str)
        for p in papers
    )
    check(fields_ok, "重评不修改 title/abstract 等原始字段")

    # 全部重评后，再跑一次应为全量跳过（真正的增量）
    again = history.reevaluate_history(papers, PaperEvaluator(), today=date.today())
    check(again["stats"]["reevaluated"] == 0,
          f"重评后再跑：0 条需重算（沿用 {again['stats']['skipped']} 条）")


def main() -> int:
    test_staleness()
    test_incremental()
    test_comparison()
    test_comparison_real_data()
    test_backup()
    test_end_to_end()

    print("\n" + "=" * 60)
    if failures:
        print(f"FAILED: {len(failures)} 项检查未通过")
        for m in failures:
            print(f"  - {m}")
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
