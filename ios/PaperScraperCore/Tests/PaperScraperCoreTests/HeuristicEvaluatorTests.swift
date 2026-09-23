//
//  HeuristicEvaluatorTests.swift
//  PaperScraperCoreTests
//
//  逐维度的分支覆盖测试。期望值均来自 CPython 实测（可由
//  `python tools/export_golden.py` 复现）。
//

import XCTest
@testable import PaperScraperCore

final class HeuristicEvaluatorTests: XCTestCase {

    private let evaluator = HeuristicEvaluator()

    // MARK: - 权重

    func testDefaultWeightsAreNormalized() {
        let weights = evaluator.weights
        XCTAssertEqual(weights.values.reduce(0, +), 1.0, accuracy: 1e-12)
        XCTAssertEqual(weights["abstract"], 0.15)
        XCTAssertEqual(weights["topic"], 0.30)
        XCTAssertEqual(weights["title"], 0.20)
        XCTAssertEqual(weights["author"], 0.20)
        XCTAssertEqual(weights["recency"], 0.15)
    }

    func testUnnormalizedWeightsAreScaledProportionally() {
        let custom = HeuristicEvaluator(weights: [
            "title": 1.0, "author": 2.0, "abstract": 3.0,
            "recency": 4.0, "topic": 5.0,
        ])
        let weights = custom.weights
        XCTAssertEqual(weights["title"]!, 0.06666666666666667, accuracy: 1e-12)
        XCTAssertEqual(weights["topic"]!, 0.3333333333333333, accuracy: 1e-12)
        XCTAssertEqual(weights.values.reduce(0, +), 1.0, accuracy: 1e-12)
    }

    // MARK: - 标题

    func testTitleScoreBranches() {
        XCTAssertEqual(evaluator.titleScore(""), 0.0)
        XCTAssertEqual(evaluator.titleScore("N/A"), 0.0)

        // 基准分 + 长度加分
        XCTAssertEqual(evaluator.titleScore("Fast Model"), 0.5, accuracy: 1e-12)

        // 含冒号 + 方法词
        let scored = evaluator.titleScore("Beyond Retrieval: A New Approach To Grounding")
        XCTAssertEqual(scored, 0.8, accuracy: 1e-12)

        // 问号结尾
        XCTAssertEqual(evaluator.titleScore("Can Diffusion Models Reason?"),
                       0.55, accuracy: 1e-12)

        // 6 词 +0.10，命中模板短语 -0.05
        XCTAssertEqual(evaluator.titleScore("Prompt Compression Is All You Need"),
                       0.55, accuracy: 1e-12)

        // 分数恒在 [0, 1]
        for title in ["x", String(repeating: "word ", count: 60),
                      "A Unified Hierarchical Framework: Is It All You Need?"] {
            let value = evaluator.titleScore(title)
            XCTAssertGreaterThanOrEqual(value, 0.0)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
    }

    // MARK: - 作者

    func testAuthorScoreBranches() {
        XCTAssertEqual(evaluator.authorScore(""), 0.2)
        XCTAssertEqual(evaluator.authorScore("N/A"), 0.2)
        XCTAssertEqual(evaluator.authorScore("Ada Lovelace"), 0.4, accuracy: 1e-12)
        XCTAssertEqual(evaluator.authorScore("Ada Lovelace, Alan Turing"),
                       0.7, accuracy: 1e-12)
        XCTAssertEqual(evaluator.authorScore("Wei Zhang, Google DeepMind"),
                       0.9, accuracy: 1e-12)
        XCTAssertEqual(evaluator.authorScore("Ada Lovelace, et al"),
                       0.65, accuracy: 1e-12)

        let many = (1...16).map { "Author \($0)" }.joined(separator: ", ")
        XCTAssertEqual(evaluator.authorScore(many), 0.45, accuracy: 1e-12)
    }

    // MARK: - 摘要

    func testAbstractScoreBranches() {
        XCTAssertEqual(evaluator.abstractScore(""), 0.0)
        XCTAssertEqual(evaluator.abstractScore("N/A"), 0.0)
        // 长度不足 100 字且无其他信号 -> 0.0
        XCTAssertEqual(evaluator.abstractScore("Short."), 0.0, accuracy: 1e-12)
        // 100~200 字 -> +0.10
        XCTAssertEqual(evaluator.abstractScore(String(repeating: "x", count: 150)),
                       0.10, accuracy: 1e-12)

        // 长度命中 500~2000
        XCTAssertEqual(evaluator.abstractScore(String(repeating: "x", count: 700)),
                       0.30, accuracy: 1e-12)

        // 方法词 + 结果词 + 百分比 + 倍数 + 信号词
        let rich = "We propose a framework and we design a benchmark dataset with an "
            + "ablation study. We achieve state-of-the-art accuracy and outperform "
            + "baselines by 7.25% while being 4x faster. " + String(repeating: "z", count: 600)
        XCTAssertEqual(evaluator.abstractScore(rich), 1.0)

        // 长度按码点计数：700 个中文字符同样落入 500~2000 区间
        XCTAssertEqual(evaluator.abstractScore(String(repeating: "中", count: 700)),
                       0.30, accuracy: 1e-12)
    }

    // MARK: - 时效性

    func testRecencyScoreBranches() throws {
        let today = try XCTUnwrap(PyCompat.parseISODate("2026-09-22"))

        func score(daysAgo: Int) throws -> Double {
            let date = try XCTUnwrap(PyCompat.parseISODate(
                PyCompat.isoDateString(Calendar.current.date(
                    byAdding: .day, value: -daysAgo, to: today)!)))
            return evaluator.recencyScore(PyCompat.isoDateString(date), today: today)
        }

        XCTAssertEqual(try score(daysAgo: 0), 1.0)
        XCTAssertEqual(try score(daysAgo: 30), 1.0)
        XCTAssertEqual(try score(daysAgo: 31), 0.9916666666666667, accuracy: 1e-12)
        XCTAssertEqual(try score(daysAgo: 60), 0.75, accuracy: 1e-12)
        XCTAssertEqual(try score(daysAgo: 90), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try score(daysAgo: 365), 0.2, accuracy: 1e-12)
        XCTAssertEqual(try score(daysAgo: 366), 0.2)

        // 未来日期会被夹到 0 天
        XCTAssertEqual(try score(daysAgo: -5), 1.0)
        // 无法解析
        XCTAssertEqual(evaluator.recencyScore("N/A", today: today), 0.3)
        XCTAssertEqual(evaluator.recencyScore("not-a-date", today: today), 0.3)
    }

    // MARK: - 主题

    func testTopicScoreBranches() {
        XCTAssertEqual(evaluator.topicScore(""), 0.0)
        XCTAssertEqual(evaluator.topicScore("geology of sedimentary basins"), 0.0)

        // 单命中 llm(w=1.0) -> 1 - exp(-0.5)
        XCTAssertEqual(evaluator.topicScore("a study of llm pipelines"),
                       1.0 - exp(-0.5), accuracy: 1e-12)

        // 多命中 -> 更接近 1.0
        let many = evaluator.topicScore("agentic rag with chain-of-thought "
            + "reasoning for multimodal diffusion alignment")
        XCTAssertGreaterThan(many, 0.9)
        XCTAssertLessThanOrEqual(many, 1.0)
    }

    // MARK: - 发表场所

    func testVenueScoreBranches() {
        XCTAssertNil(evaluator.venueScore("no signal here"))
        XCTAssertNil(evaluator.venueScore(""))
        XCTAssertEqual(evaluator.venueScore("Accepted at NeurIPS 2026."), 0.9)
        XCTAssertEqual(evaluator.venueScore("Accepted at the Efficient ML Workshop."), 0.5)
        XCTAssertEqual(evaluator.venueScore("Accepted for publication."), 0.3)

        // 已知的子串误报：600 个 w 里含 "www"，会被判成 WWW 会议
        XCTAssertEqual(evaluator.venueScore("Accepted for publication. "
            + String(repeating: "w", count: 600)), 0.9)
    }

    // MARK: - 综合分

    func testVenueRedistributesWeights() throws {
        let today = try XCTUnwrap(PyCompat.parseISODate("2026-09-22"))
        let paper = Paper(title: "Sparse Kernels For Fast Inference",
                          authors: "Ada Lovelace, Alan Turing",
                          url: "https://arxiv.org/abs/2609.00001",
                          abstract: "Accepted at NeurIPS 2026. "
                              + String(repeating: "q", count: 600),
                          submissionTime: "2026-09-10")

        let evaluation = evaluator.evaluate(paper, today: today)
        XCTAssertEqual(evaluation.dimensionScores["venue"], 0.9)
        // venue 占用 0.10，其余维度等比缩放到 0.90
        XCTAssertEqual(evaluation.weights["venue"]!, 0.10, accuracy: 1e-12)
        XCTAssertEqual(evaluation.weights["topic"]!, 0.27, accuracy: 1e-12)
        XCTAssertEqual(evaluation.weights.values.reduce(0, +), 1.0, accuracy: 1e-9)
    }

    func testFinalScoreStaysInRange() throws {
        let today = try XCTUnwrap(PyCompat.parseISODate("2026-09-22"))
        var papers: [Paper] = []
        for index in 0..<50 {
            papers.append(Paper(
                title: "Paper Number \(index) About Something Interesting",
                authors: "Ada Lovelace, Alan Turing",
                url: "https://arxiv.org/abs/2609.\(String(format: "%05d", index))",
                abstract: String(repeating: "x", count: 300 + index * 10),
                submissionTime: "2026-09-\(String(format: "%02d", index % 28 + 1))"))
        }

        let ranked = PaperEvaluator().rank(papers, today: today)
        XCTAssertEqual(ranked.count, papers.count)
        for (score, _) in ranked {
            XCTAssertGreaterThanOrEqual(score, 0.0)
            XCTAssertLessThanOrEqual(score, 100.0)
            XCTAssertFalse(score.isNaN)
        }
        // 降序
        XCTAssertEqual(ranked.map(\.score), ranked.map(\.score).sorted(by: >))
    }

    func testRankIsStableForTiedScores() {
        let papers = (0..<5).map { index in
            Paper(title: "Same Title Here",
                  authors: "A, B",
                  url: "https://arxiv.org/abs/\(index)",
                  abstract: String(repeating: "x", count: 700),
                  submissionTime: "2026-09-01")
        }
        let ranked = PaperEvaluator().rank(papers)
        // 全部同分时应保持原始顺序（Python list.sort 是稳定排序）
        XCTAssertEqual(ranked.map(\.paper.url),
                       papers.map(\.url))
    }
}
