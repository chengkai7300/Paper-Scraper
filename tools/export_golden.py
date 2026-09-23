"""export_golden.py - 导出 Python 评分内核的"金标准"，用于 Swift 实现的对拍验证。

用途
----
iOS 移植采用"Swift 重写 + Python 定规"的策略：Python 侧是既有的事实标准，
本脚本把它的输出固化成 ``golden.json``，Swift 单元测试逐条比对，
从而在**不读 Python 源码**的前提下保证两端评分口径完全一致。

关键点：日期必须可注入
----------------------
``recency`` 维度依赖"今天"，若用真实当天，金标准每天都会变化。
因此 ``evaluator`` 支持注入 ``today``，本脚本固定为 ``TODAY``。

用法
----
    python tools/export_golden.py                 # 写入 iOS 测试 Fixtures
    python tools/export_golden.py --out /tmp/g.json
    python tools/export_golden.py --real 30       # 额外纳入 30 篇真实历史记录
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date, timedelta
from typing import Any, Dict, List, Optional

# 允许从仓库根目录直接运行（python tools/export_golden.py）
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from evaluator import (  # noqa: E402
    CONTENT_FIELDS,
    TOPIC_KEYWORDS,
    HeuristicEvaluator,
    PaperEvaluator,
    kw_match,
    paper_content_hash,
)
from history import compare_before_after  # noqa: E402

#: 金标准固定"今天"。改变它会让所有 recency 相关期望值失效，需重新导出。
TODAY = date(2026, 9, 22)

DEFAULT_OUT = os.path.join(
    "ios", "PaperScraperCore", "Tests",
    "PaperScraperCoreTests", "Fixtures", "golden.json",
)

METADATA_FILE = "papers_metadata.json"

WEIGHT_SETS: Dict[str, Optional[Dict[str, float]]] = {
    # 默认权重（与 HeuristicEvaluator.DEFAULT_WEIGHTS 相同）
    "default": None,
    # 旧权重：验证"配置指纹随权重变化"以及归一化
    "old": {"title": 0.15, "author": 0.15, "abstract": 0.30,
            "recency": 0.10, "topic": 0.30},
    # 自定义权重：验证归一化（和不等于 1 时按比例缩放）
    "custom": {"title": 1.0, "author": 2.0, "abstract": 3.0,
               "recency": 4.0, "topic": 5.0},
    # 含 venue 的极端情况：只有 topic 有权重
    "topic_only": {"title": 0.0, "author": 0.0, "abstract": 0.0,
                   "recency": 0.0, "topic": 1.0},
}


def _days_ago(n: int) -> str:
    return (TODAY - timedelta(days=n)).isoformat()


# ---------------------------------------------------------------------------
# 边界用例：每个用例只负责覆盖一到两条打分分支
# ---------------------------------------------------------------------------

def build_cases() -> List[Dict[str, Any]]:
    """构造覆盖打分分支的合成论文用例。"""
    cases: List[Dict[str, Any]] = []

    def add(name: str, *, title: str = "", authors: str = "",
            abstract: str = "", submission_time: str = "N/A",
            weights: str = "default", cover: str = "",
            institutions: Optional[List[str]] = None) -> None:
        cases.append({
            "name": name,
            "cover": cover,
            "weights": weights,
            "paper": {
                "title": title,
                "authors": authors,
                "url": f"https://arxiv.org/abs/2609.{len(cases):05d}",
                "abstract": abstract,
                "submission_time": submission_time,
            },
            "institutions": institutions or [],
        })

    # ---- title ----
    add("title_empty", title="", cover="title: 空标题 -> 0.0")
    add("title_na", title="N/A", cover="title: N/A -> 0.0")
    add("title_2_words", title="Fast Model", cover="title: <5 词，无加分")
    add("title_5_words", title="A Theory Of Fast Model Inference",
        cover="title: 5~7 词 +0.10，命中 method word 'inference'? 不含")
    add("title_8_words", title="Sparse Attention Kernels For Long Context Language Modelling",
        cover="title: 8~20 词 +0.20")
    add("title_20_words",
        title="A Unified Hierarchical Framework For Robust Adaptive Efficient Scalable "
              "Multimodal Reasoning And Evaluation Of Large Language Model Agents",
        cover="title: 恰好 20 词边界")
    add("title_25_words",
        title="A Unified Hierarchical Framework For Robust Adaptive Efficient Scalable "
              "Multimodal Reasoning And Evaluation Of Large Language Model Agents In "
              "Real World Deployment Settings Today",
        cover="title: 21~25 词 +0.10")
    add("title_26_words",
        title="A Unified Hierarchical Framework For Robust Adaptive Efficient Scalable "
              "Multimodal Reasoning And Evaluation Of Large Language Model Agents In "
              "Real World Deployment Settings Today Moreover",
        cover="title: >25 词，无长度加分")
    add("title_colon", title="Beyond Retrieval: A New Approach To Grounding",
        cover="title: 含冒号 +0.10")
    add("title_question", title="Can Diffusion Models Reason?",
        cover="title: 问号结尾 +0.05")
    add("title_method_word", title="Rethinking Benchmark Design For Agents",
        cover="title: 命中 method word（benchmark / rethinking）")
    add("title_template", title="Prompt Compression Is All You Need",
        cover="title: 命中模板短语 -0.05")

    # ---- author ----
    add("author_empty", authors="", cover="author: 空 -> 0.2")
    add("author_na", authors="N/A", cover="author: N/A -> 0.2")
    add("author_single", authors="Ada Lovelace", cover="author: 单作者 -0.10")
    add("author_two", authors="Ada Lovelace, Alan Turing", cover="author: 2 人 +0.20")
    add("author_eight", authors=", ".join(f"Author {i}" for i in range(1, 9)),
        cover="author: 8 人（上限）+0.20")
    add("author_nine", authors=", ".join(f"Author {i}" for i in range(1, 10)),
        cover="author: 9 人，无人数加分")
    add("author_sixteen", authors=", ".join(f"Author {i}" for i in range(1, 17)),
        cover="author: >15 人 -0.05")
    add("author_etal", authors="Ada Lovelace, et al",
        cover="author: 含 et al -0.05")
    add("author_institution", authors="Wei Zhang, Google DeepMind",
        cover="author: 命中机构词 +0.20")
    add("author_institution_multi", authors="Li Ming, Tsinghua, Kai Chen, Microsoft",
        cover="author: 多个机构词")

    # ---- abstract ----
    add("abstract_empty", abstract="", cover="abstract: 空 -> 0.0")
    add("abstract_na", abstract="N/A", cover="abstract: N/A -> 0.0")
    add("abstract_short", abstract="Short abstract.", cover="abstract: <=100 字，无长度分")
    add("abstract_150", abstract="x" * 150, cover="abstract: 100~200 字 +0.10")
    add("abstract_300", abstract="x" * 300, cover="abstract: 200~500 字 +0.20")
    add("abstract_700", abstract="x" * 700, cover="abstract: 500~2000 字 +0.30")
    add("abstract_2500", abstract="x" * 2500, cover="abstract: 2000~3000 字 +0.20")
    add("abstract_3500", abstract="x" * 3500, cover="abstract: >3000 字，无长度分")
    add("abstract_method_hit1",
        abstract="We propose a new method. " + "y" * 600,
        cover="abstract: 命中 1 个方法词 +0.10")
    add("abstract_method_hit2",
        abstract="We propose a framework that we design for testing. " + "y" * 600,
        cover="abstract: 命中 >=2 个方法词 +0.20")
    add("abstract_result_hit1",
        abstract="Our approach improves accuracy. " + "y" * 600,
        cover="abstract: 命中 1 个结果词 +0.10")
    add("abstract_result_hit2",
        abstract="We achieve state-of-the-art accuracy and outperform baselines. " + "y" * 600,
        cover="abstract: 命中 >=2 个结果词 +0.20")
    add("abstract_percent",
        abstract="We improve accuracy by 12.5%. " + "y" * 600,
        cover="abstract: 含百分比 +0.15")
    add("abstract_multiplier",
        abstract="Our method is 3.5x faster and 2-fold cheaper. " + "y" * 600,
        cover="abstract: 含 Nx / fold +0.10")
    add("abstract_benchmark",
        abstract="We release a benchmark dataset and run an ablation study. " + "y" * 600,
        cover="abstract: 含 benchmark/dataset/ablation +0.10")
    add("abstract_all_signals",
        abstract=("We propose a unified framework and we design a benchmark dataset "
                  "with a full ablation study. We achieve state-of-the-art accuracy, "
                  "outperform all baselines and improve F1 by 7.25% while being 4x "
                  "faster. ") + ("z" * 600),
        cover="abstract: 全信号命中 -> 裁剪到 1.0")

    # ---- recency ----
    add("recency_today", submission_time=TODAY.isoformat(), cover="recency: 0 天 -> 1.0")
    add("recency_30", submission_time=_days_ago(30), cover="recency: 30 天 -> 1.0")
    add("recency_31", submission_time=_days_ago(31), cover="recency: 31 天，开始线性下降")
    add("recency_60", submission_time=_days_ago(60), cover="recency: 60 天")
    add("recency_90", submission_time=_days_ago(90), cover="recency: 90 天 -> 0.5")
    add("recency_91", submission_time=_days_ago(91), cover="recency: 91 天，第二段")
    add("recency_200", submission_time=_days_ago(200), cover="recency: 200 天")
    add("recency_365", submission_time=_days_ago(365), cover="recency: 365 天 -> 0.2")
    add("recency_366", submission_time=_days_ago(366), cover="recency: >365 天 -> 0.2")
    add("recency_future", submission_time=_days_ago(-5), cover="recency: 未来日期 -> 夹到 0 天")
    add("recency_bad", submission_time="not-a-date", cover="recency: 无法解析 -> 0.3")
    add("recency_na", submission_time="N/A", cover="recency: N/A -> 0.3")
    add("recency_unpadded", submission_time="2026-9-1",
        cover="recency: 非零填充日期（Python strptime 可解析）")

    # ---- topic ----
    add("topic_none",
        title="Geology Of Sedimentary Basins",
        abstract="We study rock formations and mineral deposits in coastal regions. " + "q" * 600,
        cover="topic: 无命中 -> 0.0")
    add("topic_single", title="A Study Of LLM Pipelines",
        abstract="w" * 600, cover="topic: 单命中 llm=1.0")
    add("topic_multi",
        title="Agentic RAG With Chain-of-Thought Reasoning For Multimodal Diffusion",
        abstract="We combine retrieval-augmented generation with alignment and "
                 "quantization for embodied robots. " + "w" * 500,
        cover="topic: 多命中 -> 趋于 1.0")
    add("topic_plural", title="Evaluating LLMs And Agents At Scale",
        abstract="w" * 600, cover="topic: 复数形式（llms / agents）")
    add("topic_boundary_negative", title="Scotland Paragraph Studies",
        abstract="w" * 600, cover="topic: 词内子串（cot in scotland, graph in paragraph）不应命中")
    add("topic_cjk", title="大语言模型在多智能体系统中的安全对齐研究",
        abstract=("本文提出一种新的框架，用于提升大语言模型的推理能力与安全性。" * 30),
        cover="topic: 中英混排（Python \\b 与 Swift 边界语义需一致）")
    add("topic_unicode", title="Étude Sur Les Modèles De Langage",
        abstract="Résumé détaillé avec des accents éàüñ. " + "w" * 600,
        cover="topic/abstract: 非 ASCII 字符长度口径")

    # ---- venue（触发 venue 维度权重再分配）----
    # 注意：stub 填充字符不能是 "w"，否则 600 个 w 会构成子串 "www"，
    # 而 "www" 正是 VENUE_TOP_TIER 中的一员，会误触发顶会判定。
    add("venue_none", title="Sparse Kernels For Fast Inference", abstract="q" * 600,
        cover="venue: 无发表信号 -> 不参与")
    add("venue_top_tier",
        title="Sparse Kernels For Fast Inference",
        abstract="Accepted at NeurIPS 2026. " + "q" * 600,
        cover="venue: 顶会 -> 0.9，并计入 0.10 权重")
    add("venue_workshop",
        title="Sparse Kernels For Fast Inference",
        abstract="Accepted at the Efficient ML Workshop. " + "q" * 600,
        cover="venue: workshop -> 0.5")
    add("venue_other",
        title="Sparse Kernels For Fast Inference",
        abstract="Accepted for publication. " + "q" * 600,
        cover="venue: 有信号但非顶会/workshop -> 0.3")
    add("venue_substring_false_positive",
        title="Sparse Kernels For Fast Inference",
        abstract="Accepted for publication. " + "w" * 600,
        cover="venue: 锁定子串匹配的已知误报（w*600 含 'www' 命中 WWW 会议）")

    # ---- institution（触发机构维度权重再分配）----
    _plain_paper = dict(title="Sparse Kernels For Fast Inference", abstract="q" * 600)
    add("institution_absent", **_plain_paper,
        cover="institution: 无机构信息 -> 该维度不参与，分数与 venue_none 相同")
    add("institution_top_tier", institutions=["Google DeepMind"], **_plain_paper,
        cover="institution: 顶尖机构 -> 1.0，并计入 0.10 权重")
    add("institution_strong_tier", institutions=["Seoul National University"],
        **_plain_paper,
        cover="institution: 第二档 -> 0.85")
    add("institution_unknown", institutions=["University of Nowhere"], **_plain_paper,
        cover="institution: 有机构但不在名单里 -> 中性 0.5")
    add("institution_best_of_many",
        institutions=["University of Nowhere", "Tsinghua University", "ACME Corp"],
        **_plain_paper,
        cover="institution: 多个机构取最好的一档")
    # 词边界反例：这三个都含有分层词表的子串，但都不该命中
    add("institution_word_boundary_smith", institutions=["Smith College"], **_plain_paper,
        cover="institution: 'Smith' 含子串 'mit'，词边界不得命中 MIT")
    add("institution_word_boundary_metabolic",
        institutions=["Department of Metabolic Biology"], **_plain_paper,
        cover="institution: 'Metabolic' 含子串 'meta'，不得命中 Meta")
    add("institution_word_boundary_ethics", institutions=["University of Ethics"],
        **_plain_paper,
        cover="institution: 'Ethics' 含子串 'eth'，不得命中 ETH Zurich")
    # 与 venue 同时出现：原有五维会被乘两次 (1 - 0.10)
    add("institution_with_venue",
        title="Sparse Kernels For Fast Inference",
        abstract="Accepted at NeurIPS 2026. " + "q" * 600,
        institutions=["Google DeepMind"],
        cover="institution: 与 venue 同时参与 -> 五维被再分配两次")

    # ---- 权重变体 ----
    add("weights_old_verbose",
        title="Rethinking Benchmark Design For Agents",
        authors="Ada Lovelace, Alan Turing, Google",
        abstract="We propose a framework and achieve state-of-the-art accuracy by 5%. " + "w" * 600,
        submission_time=_days_ago(45), weights="old",
        cover="weights: 旧权重口径")
    add("weights_custom_unnormalized",
        title="Rethinking Benchmark Design For Agents",
        authors="Ada Lovelace, Alan Turing, Google",
        abstract="We propose a framework and achieve state-of-the-art accuracy by 5%. " + "w" * 600,
        submission_time=_days_ago(45), weights="custom",
        cover="weights: 未归一化权重 -> 自动缩放")
    add("weights_topic_only_venue",
        title="Rethinking Benchmark Design For Agents",
        authors="Ada Lovelace, Google",
        abstract="Accepted at ICML 2026. We propose a framework. " + "w" * 600,
        submission_time=_days_ago(10), weights="topic_only",
        cover="weights: 零权重维度 + venue 再分配")

    return cases


def build_real_cases(limit: int) -> List[Dict[str, Any]]:
    """从真实历史记录中取若干条，作为端到端对拍用例。"""
    if not os.path.exists(METADATA_FILE):
        print(f"[warn] {METADATA_FILE} 不存在，跳过真实用例。")
        return []
    with open(METADATA_FILE, "r", encoding="utf-8") as f:
        papers = json.load(f)
    out = []
    for i, paper in enumerate(papers[:limit]):
        stripped = {k: paper.get(k, "") for k in
                    ("title", "authors", "url", "abstract", "submission_time")}
        out.append({
            "name": f"real_{i:03d}",
            "cover": "真实历史记录",
            "weights": "default",
            "paper": stripped,
        })
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="导出 Python 评分内核金标准")
    parser.add_argument("--out", default=DEFAULT_OUT, help=f"输出路径（默认 {DEFAULT_OUT}）")
    parser.add_argument("--real", type=int, default=25,
                        help="额外纳入多少条真实历史记录（默认 25，0 表示不纳入）")
    args = parser.parse_args()

    cases = build_cases() + build_real_cases(args.real)

    # ---- 逐用例求期望值 ----
    evaluators: Dict[str, PaperEvaluator] = {}
    heuristics: Dict[str, HeuristicEvaluator] = {}
    for name, weights in WEIGHT_SETS.items():
        evaluators[name] = PaperEvaluator(weights=weights)
        heuristics[name] = HeuristicEvaluator(weights=weights)

    expected_cases = []
    for case in cases:
        key = case["weights"]
        heur = heuristics[key]
        paper = case["paper"]

        # 维度分（供 Swift 逐维度比对，便于定位偏差来源）
        institutions = case.get("institutions") or []
        dims = heur.evaluate(paper, today=TODAY, institutions=institutions)

        # 组合评分（含 config_key / content_hash / evaluated_on）
        full = evaluators[key].evaluate(paper, today=TODAY,
                                        institutions=institutions)

        expected_cases.append({
            "name": case["name"],
            "cover": case["cover"],
            "weights": key,
            "paper": paper,
            "institutions": institutions,
            "expected": {
                "dimension_scores": dims["dimension_scores"],
                "normalized_weights": dims["weights"],
                "final_score": dims["final_score"],
                "dimension_scores_with_meta": full["dimension_scores"],
                "config_key": full["config_key"],
                "content_hash": full["content_hash"],
                "evaluated_on": full["evaluated_on"],
            },
        })

    # ---- 权重归一化快照 ----
    normalized_weights = {
        name: {k: round(v, 6) for k, v in heur.weights.items()}
        for name, heur in heuristics.items()
    }

    # ---- 配置指纹：每个权重集 + 增强开关组合 ----
    config_keys = {}
    for name, weights in WEIGHT_SETS.items():
        for external in (False, True):
            for llm in (False, True):
                ev = PaperEvaluator(weights=weights, use_external=external,
                                    use_llm=llm)
                if llm and not ev.llm_enabled:
                    # 无 OPENAI_API_KEY 时 llm_enabled 为 False，指纹与 llm=False 相同
                    continue
                config_keys[f"{name}|external={external}|llm={llm}"] = ev.config_key

    # ---- 内容指纹 ----
    hash_cases = []
    for case in cases[:12]:
        hash_cases.append({
            "name": case["name"],
            "paper": case["paper"],
            "hash": paper_content_hash(case["paper"]),
        })
    # 补充：字段为空 / 缺键 / None 的处理
    for name, paper in (
        ("hash_all_empty", {k: "" for k in CONTENT_FIELDS}),
        ("hash_missing_keys", {}),
        ("hash_none_values", {k: None for k in CONTENT_FIELDS}),
        ("hash_unicode", {"title": "中文标题", "authors": "张三, 李四",
                          "abstract": "摘要内容", "submission_time": "2026-09-01"}),
    ):
        hash_cases.append({"name": name, "paper": paper,
                           "hash": paper_content_hash(paper)})

    # ---- 关键词词表 + 匹配判定 ----
    keyword_probes = [
        "llm", "llms", "LLM", "large language model", "xllm", "llmX",
        "cot", "scotland", "graph", "paragraph", "rag", "storage",
        "multi-agent", "multi-agents", "chain-of-thought",
        "retrieval-augmented", "kv cache", "kv caches",
        "大语言模型的llm能力", "  llm  ",
    ]
    keyword_hits = {
        text: sorted(kw for kw in TOPIC_KEYWORDS if kw_match(kw, text.lower()))
        for text in keyword_probes
    }

    # ---- history 对比指标（与 test_history.py 的合成场景一致）----
    compare_papers = [{"title": f"P{i}", "url": f"u{i}"} for i in range(4)]
    compare_before = [{"score": s, "dims": {"title": 0.5, "abstract": 1.0}}
                      for s in (90.0, 80.0, 70.0, 60.0)]
    compare_after = [{"score": s, "dims": {"title": 0.5, "abstract": 1.0}}
                     for s in (85.0, 95.0, 99.0, 70.0)]
    comparison = compare_before_after(compare_papers, compare_before,
                                      compare_after, top_n=2)
    # 只保留 Swift 测试需要且可序列化的部分
    comparison_golden = {
        "comparable": comparison["comparable"],
        "changed": comparison["changed"],
        "mean_delta": comparison["mean_delta"],
        "mean_abs_delta": comparison["mean_abs_delta"],
        "max_up_title": comparison["max_up"]["title"],
        "max_up_delta": comparison["max_up"]["score_delta"],
        "max_down_title": comparison["max_down"]["title"],
        "max_down_delta": comparison["max_down"]["score_delta"],
        "top_overlap": comparison["top_overlap"],
        "spearman": comparison["spearman"],
        "entries": [
            {"title": e["title"], "before_score": e["before_score"],
             "after_score": e["after_score"], "score_delta": e["score_delta"],
             "before_rank": e["before_rank"], "after_rank": e["after_rank"],
             "rank_delta": e["rank_delta"]}
            for e in comparison["entries"]
        ],
        "top_after_titles": [e["title"] for e in comparison["top_after"]],
    }

    golden = {
        "_comment": "由 tools/export_golden.py 生成，请勿手改。Swift 侧 GoldenParityTests 逐条比对。",
        "today": TODAY.isoformat(),
        "default_weights": HeuristicEvaluator.DEFAULT_WEIGHTS,
        "weight_sets": {k: (v or HeuristicEvaluator.DEFAULT_WEIGHTS)
                        for k, v in WEIGHT_SETS.items()},
        "normalized_weights": normalized_weights,
        "config_keys": config_keys,
        "topic_keywords": TOPIC_KEYWORDS,
        "keyword_hits": keyword_hits,
        "content_hashes": hash_cases,
        "comparison": comparison_golden,
        "cases": expected_cases,
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(golden, f, indent=1, ensure_ascii=False, sort_keys=False)

    size = os.path.getsize(args.out)
    print(f"金标准已写入 {args.out}")
    print(f"  用例数        : {len(expected_cases)}")
    print(f"  真实用例      : {sum(1 for c in expected_cases if c['name'].startswith('real_'))}")
    print(f"  配置指纹      : {len(config_keys)}")
    print(f"  内容指纹      : {len(hash_cases)}")
    print(f"  关键词探针    : {len(keyword_hits)}")
    print(f"  文件大小      : {size / 1024:.1f} KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
