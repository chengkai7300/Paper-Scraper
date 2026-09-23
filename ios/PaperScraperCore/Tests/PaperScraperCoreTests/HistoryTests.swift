//
//  HistoryTests.swift
//  PaperScraperCoreTests
//
//  `test_history.py` 的 Swift 移植版：覆盖 staleness 的五条判断路径、
//  增量语义、对比指标与真实数据端到端。
//

import XCTest
@testable import PaperScraperCore

final class HistoryTests: XCTestCase {

    private let today = PyCompat.parseISODate("2026-09-16")!
    private var todayStamp: String { PyCompat.isoDateString(today) }

    private let oldWeights: [String: Double] = [
        "title": 0.15, "author": 0.15, "abstract": 0.30,
        "recency": 0.10, "topic": 0.30,
    ]

    // MARK: - 构造工具

    private func makePaper(title: String = "A Test Paper",
                           abstract: String = String(repeating: "x", count: 700)) -> Paper {
        Paper(title: title,
              authors: "Alice, Bob",
              url: "https://arxiv.org/abs/2609.00001",
              abstract: abstract,
              submissionTime: "2026-09-10")
    }

    /// 构造一条"历史记录"：先正常评分，再按需覆写溯源字段。
    ///
    /// 参数用**双层可选**表达 Python 里的 `_UNSET` 语义：
    /// `nil` = 不动，`.some(nil)` = 写入 nil，`.some(value)` = 写入 value。
    @discardableResult
    private func stored(_ paper: Paper,
                        evaluator: PaperEvaluator,
                        weights: [String: Double]?? = nil,
                        evaluatedOn: String?? = nil,
                        configKey: String?? = nil,
                        contentHash: String?? = nil) -> Paper {
        var result = paper
        var evaluation = evaluator.evaluate(paper, today: today)
        if let weights { evaluation.weights = weights ?? [:] }
        if let evaluatedOn { evaluation.evaluatedOn = evaluatedOn }
        if let configKey { evaluation.configKey = configKey }
        if let contentHash { evaluation.contentHash = contentHash }
        result.evaluation = evaluation
        return result
    }

    // MARK: - 1. staleness 判断路径

    func testStalenessPaths() {
        let evaluator = PaperEvaluator()

        // 1.1 无历史评分
        XCTAssertEqual(History.stalenessReason(makePaper(), evaluator: evaluator,
                                               today: today), .missing)

        // 1.2 旧权重且无指纹（真实老记录的形态）
        let legacy = stored(makePaper(), evaluator: evaluator,
                            weights: .some(oldWeights),
                            evaluatedOn: .some(nil),
                            configKey: .some(nil))
        XCTAssertEqual(History.stalenessReason(legacy, evaluator: evaluator,
                                               today: today), .configChanged)

        // 1.3 权重一致、仅缺指纹 -> 视为同口径，继续看日期
        let sameWeights = stored(makePaper(), evaluator: evaluator,
                                 weights: .some(evaluator.heuristic.weights),
                                 evaluatedOn: .some(todayStamp),
                                 configKey: .some(nil))
        XCTAssertNil(History.stalenessReason(sameWeights, evaluator: evaluator,
                                             today: today))

        // 1.4 指纹不匹配
        let wrongKey = stored(makePaper(), evaluator: evaluator,
                              evaluatedOn: .some(todayStamp),
                              configKey: .some("deadbeef0000"))
        XCTAssertEqual(History.stalenessReason(wrongKey, evaluator: evaluator,
                                               today: today), .configChanged)

        // 1.5 内容变更
        var changed = stored(makePaper(), evaluator: evaluator,
                             evaluatedOn: .some(todayStamp))
        changed.abstract += " 新增内容"
        XCTAssertEqual(History.stalenessReason(changed, evaluator: evaluator,
                                               today: today), .contentChanged)

        // 1.6 跨天
        let yesterday = PyCompat.isoDateString(
            Calendar.current.date(byAdding: .day, value: -1, to: today)!)
        let stale = stored(makePaper(), evaluator: evaluator,
                           evaluatedOn: .some(yesterday))
        XCTAssertEqual(History.stalenessReason(stale, evaluator: evaluator,
                                               today: today), .recencyExpired)

        // 1.7 完全新鲜
        let fresh = stored(makePaper(), evaluator: evaluator,
                           evaluatedOn: .some(todayStamp))
        XCTAssertNil(History.stalenessReason(fresh, evaluator: evaluator, today: today))
    }

    func testContentHashProperties() {
        let a = makePaper(title: "T1")
        let b = makePaper(title: "T1")
        let c = makePaper(title: "T2")

        XCTAssertEqual(PaperEvaluator.contentHash(a), PaperEvaluator.contentHash(b))
        XCTAssertNotEqual(PaperEvaluator.contentHash(a), PaperEvaluator.contentHash(c))

        // 缺字段与空字段等价（对齐 Python 的 `paper.get(k) or ""`）
        let empty = PaperEvaluator.contentHash(title: "", authors: "",
                                               abstract: "", submissionTime: "")
        let missing = PaperEvaluator.contentHash(title: "", authors: "",
                                                 abstract: "", submissionTime: "")
        XCTAssertEqual(empty, missing)
    }

    // MARK: - 2. 增量语义

    func testIncrementalSemantics() {
        let evaluator = PaperEvaluator()
        var papers = (0..<5).map { makePaper(title: "P\($0)") }

        // 2.1 首次：全部 missing
        var result = History.reevaluateHistory(&papers, evaluator: evaluator, today: today)
        XCTAssertEqual(result.stats.reevaluated, 5)
        XCTAssertEqual(result.stats.reasons[.missing], 5)

        // 2.2 同配置同日期重跑：全部跳过（这才是"增量"）
        result = History.reevaluateHistory(&papers, evaluator: evaluator, today: today)
        XCTAssertEqual(result.stats.reevaluated, 0)
        XCTAssertEqual(result.stats.skipped, 5)

        // 2.3 跨天：全部按 recency 刷新
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        result = History.reevaluateHistory(&papers, evaluator: evaluator, today: tomorrow)
        XCTAssertEqual(result.stats.reasons[.recencyExpired], 5)

        // 2.4 换权重：全部按配置变更刷新
        let newEvaluator = PaperEvaluator(weights: [
            "title": 0.4, "author": 0.1, "abstract": 0.2, "recency": 0.1, "topic": 0.2,
        ])
        result = History.reevaluateHistory(&papers, evaluator: newEvaluator, today: today)
        XCTAssertEqual(result.stats.reasons[.configChanged], 5)

        // 2.5 force：忽略增量判断
        result = History.reevaluateHistory(&papers, evaluator: newEvaluator,
                                           force: true, today: today)
        XCTAssertEqual(result.stats.reevaluated, 5)
        XCTAssertEqual(result.stats.reasons[.forced], 5)

        // 2.6 幂等性
        let first = History.reevaluateHistory(&papers, evaluator: newEvaluator,
                                              force: true, today: today)
        let second = History.reevaluateHistory(&papers, evaluator: newEvaluator,
                                               force: true, today: today)
        XCTAssertEqual(first.after.compactMap { $0?.score },
                       second.after.compactMap { $0?.score })
    }

    // MARK: - 2.5 重评必须保留"有条件参与"的维度

    /// 机构维度是**有条件参与**的（无数据时不参与）。重评时要是不把它传进去，
    /// 已经并入机构的论文分数会悄悄退回旧口径 —— 这个回归真实发生过，
    /// 因为 `History.run` 原本只调 `evaluate(paper, today:)`。
    func testReevaluationPreservesInstitutionDimension() {
        let evaluator = PaperEvaluator()
        let paper = makePaper()
        let institutions = ["Google DeepMind"]

        // 先按"带机构"的口径评一次并落盘
        var scored = paper
        scored.evaluation = evaluator.evaluate(paper, institutions: institutions,
                                               today: today)
        let scorerWithInstitution = scored.evaluation?.finalScore
        XCTAssertNotNil(scored.evaluation?.dimensionScores["institution"])

        var papers = [scored]

        // 不传机构：维度会丢，分数退回
        var withoutProvider = papers
        _ = History.reevaluateHistory(&withoutProvider, evaluator: evaluator,
                                      force: true, today: today)
        XCTAssertNil(withoutProvider[0].evaluation?.dimensionScores["institution"],
                     "不传提供者时机构维度确实会丢（这正说明必须传）")
        XCTAssertNotEqual(withoutProvider[0].evaluation?.finalScore,
                          scorerWithInstitution)

        // 传了机构：维度保留，分数与首次一致
        _ = History.reevaluateHistory(&papers, evaluator: evaluator,
                                      force: true, today: today,
                                      institutions: { _ in institutions })
        XCTAssertEqual(papers[0].evaluation?.dimensionScores["institution"], 1.0)
        XCTAssertEqual(papers[0].evaluation?.finalScore ?? -1,
                       scorerWithInstitution ?? -2)
    }

    /// 报告里的维度名要能翻译出中文，不能漏出原始键名 `institution`。
    func testInstitutionDimensionHasChineseLabel() {
        XCTAssertEqual(DimensionLabels.label("institution"), "机构")
        for key in DimensionLabels.allKeys {
            XCTAssertNotEqual(DimensionLabels.label(key), key,
                              "维度 \(key) 缺少中文名")
        }
    }

    // MARK: - 3. 对比指标

    func testComparisonMetrics() {
        let papers = (0..<4).map {
            Paper(title: "P\($0)", authors: "A", url: "u\($0)",
                  abstract: "", submissionTime: "N/A")
        }
        let before: [ScoreSnapshot?] = [90.0, 80.0, 70.0, 60.0].map {
            ScoreSnapshot(score: $0, dims: ["title": 0.5, "abstract": 1.0])
        }
        let after: [ScoreSnapshot?] = [85.0, 95.0, 99.0, 70.0].map {
            ScoreSnapshot(score: $0, dims: ["title": 0.5, "abstract": 1.0])
        }

        let comparison = History.compareBeforeAfter(papers, before: before,
                                                    after: after, topN: 2)

        XCTAssertEqual(comparison.comparable, 4)
        XCTAssertEqual(comparison.changed, 4)
        XCTAssertEqual(comparison.meanDelta, 12.25, accuracy: 1e-9)
        XCTAssertEqual(comparison.meanAbsDelta, 14.75, accuracy: 1e-9)
        XCTAssertEqual(comparison.maxUp?.title, "P2")
        XCTAssertEqual(comparison.maxUp?.scoreDelta ?? 0, 29.0, accuracy: 1e-9)
        XCTAssertEqual(comparison.maxDown?.title, "P0")
        XCTAssertEqual(comparison.maxDown?.scoreDelta ?? 0, -5.0, accuracy: 1e-9)
        XCTAssertEqual(comparison.topOverlap, 1)
        XCTAssertEqual(comparison.spearman, 0.2, accuracy: 1e-9)

        let rankDeltas = Dictionary(uniqueKeysWithValues:
            comparison.topBefore.map { ($0.title, $0.rankDelta) })
        XCTAssertEqual(rankDeltas, ["P0": -2, "P1": 0])

        // 维度原始分不受权重影响
        for delta in comparison.dimDeltas {
            XCTAssertEqual(delta.before, delta.after, accuracy: 1e-9)
        }

        // 名次是 1..n 的置换，变动之和必为 0
        XCTAssertEqual(comparison.entries.reduce(0) { $0 + $1.rankDelta }, 0)
        XCTAssertEqual(comparison.entries.count, 4)

        // 空输入不应崩
        let empty = History.compareBeforeAfter([], before: [], after: [])
        XCTAssertEqual(empty.comparable, 0)
        XCTAssertEqual(empty.topOverlap, 0)
        XCTAssertEqual(empty.spearman, 1.0)
    }

    // MARK: - 4. 报告

    func testReportContainsAllSections() {
        let evaluator = PaperEvaluator()
        let legacyEvaluator = PaperEvaluator(weights: oldWeights)
        var papers = (0..<6).map { makePaper(title: "Report Paper \($0)") }

        // 先用旧权重评一遍，制造"有历史评分"的状态，
        // 否则 before 全为 nil，报告里不会出现对比小节。
        _ = History.reevaluateHistory(&papers, evaluator: legacyEvaluator, today: today)
        let result = History.run(&papers, evaluator: evaluator, topN: 3, today: today)

        for section in ["历史回溯", "评分口径", "排序稳定性", "维度平均分变化",
                        "新口径 Top-3", "可对比集合"] {
            XCTAssertTrue(result.report.contains(section),
                          "报告缺少「\(section)」小节")
        }
        XCTAssertEqual(result.stats.total, 6)
        XCTAssertEqual(result.stats.reevaluated, 6)
        XCTAssertEqual(result.comparison.comparable, 6)
    }

    // MARK: - 5. 备份

    func testBackupNamingMatchesPython() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("paper-scraper-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadataURL = directory.appendingPathComponent("papers_metadata.json")
        try PaperStore.save([makePaper()], to: metadataURL)

        let backupURL = try PaperStore.backup(of: metadataURL)
        XCTAssertEqual(backupURL.lastPathComponent, "papers_metadata.backup.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        // 备份内容应与原文件一致
        let original = try Data(contentsOf: metadataURL)
        let copy = try Data(contentsOf: backupURL)
        XCTAssertEqual(original, copy)
    }
}
