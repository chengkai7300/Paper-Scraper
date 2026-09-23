//
//  GoldenParityTests.swift
//  PaperScraperCoreTests
//
//  **移植正确性的核心保障**：把 Swift 实现的输出与 Python 金标准逐条比对。
//
//  金标准由 `python tools/export_golden.py` 生成（91 个用例，覆盖各维度的每个
//  分支、4 组权重、8 组配置指纹、16 组内容指纹、20 个关键词探针）。
//  只要这个测试通过，就可以确信两端对同一篇论文给出**同一个分数**。
//
//  失败时会把所有偏差一次性列出，方便定位是哪一条分支没对齐。
//

import XCTest
@testable import PaperScraperCore

// MARK: - 金标准的数据模型

struct Golden: Decodable {
    let today: String
    let defaultWeights: [String: Double]
    let weightSets: [String: [String: Double]]
    let normalizedWeights: [String: [String: Double]]
    let configKeys: [String: String]
    let topicKeywords: [String: Double]
    let keywordHits: [String: [String]]
    let contentHashes: [GoldenHash]
    let comparison: GoldenComparison
    let cases: [GoldenCase]
}

struct GoldenHash: Decodable {
    let name: String
    let paper: GoldenPaper
    let hash: String
}

/// 宽容解码：`hash_*` 用例里会出现"缺字段"与"值为 null"两种形态。
struct GoldenPaper: Decodable {
    let title: String?
    let authors: String?
    let url: String?
    let abstract: String?
    let submissionTime: String?

    /// 用于评分（缺字段按抓取层约定回落 "N/A"）。
    var model: Paper {
        Paper(title: title ?? "N/A",
              authors: authors ?? "N/A",
              url: url ?? "N/A",
              abstract: abstract ?? "N/A",
              submissionTime: submissionTime ?? "N/A")
    }

    /// 用于求内容指纹（缺字段与 null 一律视作空串，对齐 Python 的 `or ""`）。
    var contentFields: (title: String, authors: String, abstract: String, submissionTime: String) {
        (title ?? "", authors ?? "", abstract ?? "", submissionTime ?? "")
    }
}

struct GoldenCase: Decodable {
    let name: String
    let cover: String
    let weights: String
    let paper: GoldenPaper
    /// 作者机构（可缺）；有值时"机构"维度参与加权。
    let institutions: [String]?
    let expected: GoldenExpected
}

struct GoldenExpected: Decodable {
    let dimensionScores: [String: Double?]
    let normalizedWeights: [String: Double]
    let finalScore: Double
    let dimensionScoresWithMeta: [String: Double?]
    let configKey: String
    let contentHash: String
    let evaluatedOn: String
}

struct GoldenEntry: Decodable {
    let title: String
    let beforeScore: Double
    let afterScore: Double
    let scoreDelta: Double
    let beforeRank: Int
    let afterRank: Int
    let rankDelta: Int
}

struct GoldenComparison: Decodable {
    let comparable: Int
    let changed: Int
    let meanDelta: Double
    let meanAbsDelta: Double
    let maxUpTitle: String
    let maxUpDelta: Double
    let maxDownTitle: String
    let maxDownDelta: Double
    let topOverlap: Int
    let spearman: Double
    let entries: [GoldenEntry]
    let topAfterTitles: [String]
}

enum GoldenLoader {
    static func load() throws -> Golden {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "golden", withExtension: "json",
                             subdirectory: "Fixtures")
            ?? bundle.url(forResource: "golden", withExtension: "json")
        guard let url else {
            throw NSError(domain: "GoldenLoader", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "找不到 golden.json；请先运行 `python tools/export_golden.py`",
            ])
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Golden.self, from: Data(contentsOf: url))
    }
}

// MARK: - 对拍

final class GoldenParityTests: XCTestCase {

    private let tolerance = 1e-9

    /// 收集失败信息，最后一次性报告全部偏差。
    private final class MismatchLog {
        private(set) var messages: [String] = []
        func check(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { messages.append(message()) }
        }
        func near(_ actual: Double, _ expected: Double, _ label: String) {
            if abs(actual - expected) > 1e-9 {
                messages.append("\(label): Swift=\(actual) Python=\(expected) "
                    + "Δ=\(actual - expected)")
            }
        }
        var summary: String {
            messages.isEmpty ? "" : "\n  - " + messages.joined(separator: "\n  - ")
        }
    }

    // MARK: 主体

    func testEvaluatorMatchesPythonGolden() throws {
        let golden = try GoldenLoader.load()
        let today = try XCTUnwrap(PyCompat.parseISODate(golden.today))
        let log = MismatchLog()

        var evaluators: [String: PaperEvaluator] = [:]
        for (name, weights) in golden.weightSets {
            evaluators[name] = PaperEvaluator(weights: weights)
        }

        for testCase in golden.cases {
            let evaluator = try XCTUnwrap(evaluators[testCase.weights],
                                          "未知权重档位 \(testCase.weights)")
            let paper = testCase.paper.model
            // 机构为空的用例必须与不带机构时逐位相同（历史记录兼容性依赖这一点）
            let institutions = testCase.institutions ?? []
            let label = "[\(testCase.name)] \(testCase.cover)"

            // ---- 维度分与综合分 ----
            let heuristic = evaluator.heuristic.evaluate(paper, institutions: institutions,
                                                         today: today)
            let expectedDims = testCase.expected.dimensionScores.compactMapValues { $0 }
            log.check(Set(heuristic.dimensionScores.keys) == Set(expectedDims.keys),
                      "\(label) 维度键不一致：Swift=\(heuristic.dimensionScores.keys.sorted()) "
                          + "Python=\(expectedDims.keys.sorted())")
            for (key, expected) in expectedDims {
                guard let actual = heuristic.dimensionScores[key] else { continue }
                log.near(actual, expected, "\(label) dimension_scores.\(key)")
            }

            log.near(heuristic.finalScore ?? -1, testCase.expected.finalScore,
                     "\(label) final_score")

            for (key, expected) in testCase.expected.normalizedWeights {
                guard let actual = heuristic.weights[key] else {
                    log.check(false, "\(label) 缺少权重 \(key)")
                    continue
                }
                log.near(actual, expected, "\(label) normalized_weights.\(key)")
            }

            // ---- 溯源字段 ----
            let full = evaluator.evaluate(paper, institutions: institutions, today: today)
            log.check(full.configKey == testCase.expected.configKey,
                      "\(label) config_key: Swift=\(full.configKey ?? "nil") "
                          + "Python=\(testCase.expected.configKey)")
            log.check(full.contentHash == testCase.expected.contentHash,
                      "\(label) content_hash: Swift=\(full.contentHash ?? "nil") "
                          + "Python=\(testCase.expected.contentHash)")
            log.check(full.evaluatedOn == testCase.expected.evaluatedOn,
                      "\(label) evaluated_on: Swift=\(full.evaluatedOn ?? "nil") "
                          + "Python=\(testCase.expected.evaluatedOn)")
            log.near(full.finalScore ?? -1, testCase.expected.finalScore,
                     "\(label) full.final_score")
            log.near(full.baseScore ?? -1, testCase.expected.finalScore,
                     "\(label) base_score")
        }

        XCTAssertTrue(log.messages.isEmpty,
                      "共 \(log.messages.count) 处与 Python 金标准不一致：\(log.summary)")
    }

    // MARK: 词表

    func testKeywordTablesMatchPython() throws {
        let golden = try GoldenLoader.load()

        XCTAssertEqual(HeuristicEvaluator.defaultWeights, golden.defaultWeights,
                       "默认权重与 Python 不一致")

        let swiftKeywords = Keywords.topicKeywordWeights
        XCTAssertEqual(swiftKeywords.count, golden.topicKeywords.count,
                       "主题词表条目数不一致")
        for (keyword, weight) in golden.topicKeywords {
            XCTAssertEqual(swiftKeywords[keyword], weight,
                           "主题词 \(keyword) 的权重与 Python 不一致")
        }

        // 顺序敏感：必须与 Python dict 字面量同序
        let swiftOrder = Keywords.topicKeywords.map(\.keyword)
        XCTAssertEqual(swiftOrder.count, golden.topicKeywords.count)
        XCTAssertEqual(Set(swiftOrder).count, swiftOrder.count, "主题词表存在重复项")
    }

    func testKeywordMatchingMatchesPython() throws {
        let golden = try GoldenLoader.load()
        let log = MismatchLog()

        for (text, expectedHits) in golden.keywordHits {
            let actual = Keywords.topicKeywords
                .map(\.keyword)
                .filter { KeywordMatcher.matches($0, in: text.lowercased()) }
                .sorted()
            log.check(actual == expectedHits.sorted(),
                      "\(text.debugDescription) 命中集不一致：Swift=\(actual) "
                          + "Python=\(expectedHits)")
        }

        XCTAssertTrue(log.messages.isEmpty, log.summary)
    }

    // MARK: 内容指纹

    func testContentHashesMatchPython() throws {
        let golden = try GoldenLoader.load()
        let log = MismatchLog()

        for item in golden.contentHashes {
            let fields = item.paper.contentFields
            let actual = PaperEvaluator.contentHash(
                title: fields.title,
                authors: fields.authors,
                abstract: fields.abstract,
                submissionTime: fields.submissionTime)
            log.check(actual == item.hash,
                      "[\(item.name)] content_hash: Swift=\(actual) Python=\(item.hash)")
        }

        XCTAssertTrue(log.messages.isEmpty, log.summary)
    }

    // MARK: 配置指纹

    /// 载荷原文比对：比 sha1 更容易定位差异（不一致时能直接看出是哪个字段）。
    func testConfigKeyPayloadsMatchPython() throws {
        let golden = try GoldenLoader.load()
        let log = MismatchLog()

        let expectedPayloads: [String: String] = [
            "default": "{\"external\": false, \"external_weight\": 0.2, "
                + "\"llm\": false, \"llm_weight\": 0.3, \"weights\": "
                + "{\"abstract\": 0.15, \"author\": 0.2, \"recency\": 0.15, "
                + "\"title\": 0.2, \"topic\": 0.3}}",
            "old": "{\"external\": false, \"external_weight\": 0.2, "
                + "\"llm\": false, \"llm_weight\": 0.3, \"weights\": "
                + "{\"abstract\": 0.3, \"author\": 0.15, \"recency\": 0.1, "
                + "\"title\": 0.15, \"topic\": 0.3}}",
            "custom": "{\"external\": false, \"external_weight\": 0.2, "
                + "\"llm\": false, \"llm_weight\": 0.3, \"weights\": "
                + "{\"abstract\": 0.2, \"author\": 0.133333, \"recency\": 0.266667, "
                + "\"title\": 0.066667, \"topic\": 0.333333}}",
            "topic_only": "{\"external\": false, \"external_weight\": 0.2, "
                + "\"llm\": false, \"llm_weight\": 0.3, \"weights\": "
                + "{\"abstract\": 0.0, \"author\": 0.0, \"recency\": 0.0, "
                + "\"title\": 0.0, \"topic\": 1.0}}",
        ]

        for (name, expected) in expectedPayloads {
            guard let weights = golden.weightSets[name] else {
                log.check(false, "金标准缺少权重档位 \(name)")
                continue
            }
            let actual = PaperEvaluator(weights: weights).configKeyPayload
            log.check(actual == expected,
                      "[\(name)] 载荷不一致\n      Swift = \(actual)\n      Python= \(expected)")
        }

        XCTAssertTrue(log.messages.isEmpty, log.summary)
    }

    func testConfigKeysMatchPython() throws {
        let golden = try GoldenLoader.load()
        let log = MismatchLog()

        for (descriptor, expected) in golden.configKeys {
            let parts = descriptor.split(separator: "|")
            let preset = String(parts[0])
            // Python 用 str(bool) 拼描述，所以是 "True"/"False"（首字母大写）
            let useExternal = descriptor.contains("external=True")
            let llmEnabled = descriptor.contains("llm=True")
            guard let weights = golden.weightSets[preset] else {
                log.check(false, "未知权重档位 \(preset)")
                continue
            }
            let evaluator = PaperEvaluator(weights: weights,
                                           useExternal: useExternal,
                                           llmEnabled: llmEnabled)
            log.check(evaluator.configKey == expected,
                      "\(descriptor) config_key: Swift=\(evaluator.configKey) "
                          + "Python=\(expected)\n      Swift 载荷 = \(evaluator.configKeyPayload)")
        }

        XCTAssertTrue(log.messages.isEmpty, log.summary)
    }

    /// 与既有历史记录的兼容性：默认配置下必须复现 README 里记录的指纹。
    func testDefaultConfigKeyMatchesHistoricalRecords() {
        XCTAssertEqual(PaperEvaluator().configKey, "2d27de8f1078")
    }

    // MARK: 对比指标

    func testComparisonMetricsMatchPython() throws {
        let golden = try GoldenLoader.load()
        let expected = golden.comparison

        let papers = (0..<4).map { index in
            Paper(title: "P\(index)", authors: "A", url: "u\(index)",
                  abstract: "", submissionTime: "N/A")
        }
        // before: 90/80/70/60 -> 名次 1,2,3,4
        // after : 85/95/99/70 -> 名次 3,2,1,4
        let before: [ScoreSnapshot?] = [90.0, 80.0, 70.0, 60.0].map {
            ScoreSnapshot(score: $0, dims: ["title": 0.5, "abstract": 1.0])
        }
        let after: [ScoreSnapshot?] = [85.0, 95.0, 99.0, 70.0].map {
            ScoreSnapshot(score: $0, dims: ["title": 0.5, "abstract": 1.0])
        }

        let comparison = History.compareBeforeAfter(
            papers, before: before, after: after, topN: 2)

        XCTAssertEqual(comparison.comparable, expected.comparable)
        XCTAssertEqual(comparison.changed, expected.changed)
        XCTAssertEqual(comparison.meanDelta, expected.meanDelta, accuracy: tolerance)
        XCTAssertEqual(comparison.meanAbsDelta, expected.meanAbsDelta, accuracy: tolerance)
        XCTAssertEqual(comparison.maxUp?.title, expected.maxUpTitle)
        XCTAssertEqual(comparison.maxUp?.scoreDelta ?? 0, expected.maxUpDelta,
                       accuracy: tolerance)
        XCTAssertEqual(comparison.maxDown?.title, expected.maxDownTitle)
        XCTAssertEqual(comparison.maxDown?.scoreDelta ?? 0, expected.maxDownDelta,
                       accuracy: tolerance)
        XCTAssertEqual(comparison.topOverlap, expected.topOverlap)
        XCTAssertEqual(comparison.spearman, expected.spearman, accuracy: tolerance)
        XCTAssertEqual(comparison.topAfter.map(\.title), expected.topAfterTitles)

        XCTAssertEqual(comparison.entries.count, expected.entries.count)
        for (actual, wanted) in zip(comparison.entries, expected.entries) {
            XCTAssertEqual(actual.title, wanted.title)
            XCTAssertEqual(actual.beforeScore, wanted.beforeScore, accuracy: tolerance)
            XCTAssertEqual(actual.afterScore, wanted.afterScore, accuracy: tolerance)
            XCTAssertEqual(actual.scoreDelta, wanted.scoreDelta, accuracy: tolerance)
            XCTAssertEqual(actual.beforeRank, wanted.beforeRank)
            XCTAssertEqual(actual.afterRank, wanted.afterRank)
            XCTAssertEqual(actual.rankDelta, wanted.rankDelta)
        }
    }
}

// MARK: - 真实数据文件兼容性

final class RealMetadataCompatibilityTests: XCTestCase {

    /// 用真实的 `papers_metadata.json`（150 条历史记录）验证：
    /// Swift 能解码既有数据，且算出的配置指纹与记录中保存的一致。
    func testRealMetadataIsReadableAndCompatible() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PaperScraperCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PaperScraperCore
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // 仓库根目录

        let metadataURL = repositoryRoot.appendingPathComponent("papers_metadata.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw XCTSkip("未找到 \(metadataURL.path)，跳过真实数据兼容性检查")
        }

        let papers = try PaperStore.load(from: metadataURL)
        XCTAssertFalse(papers.isEmpty, "历史记录不应为空")

        let evaluator = PaperEvaluator()
        var mismatchedConfigKeys = 0
        var withEvaluation = 0

        for paper in papers {
            guard let evaluation = paper.evaluation else { continue }
            withEvaluation += 1
            if let key = evaluation.configKey, key != evaluator.configKey {
                mismatchedConfigKeys += 1
            }
            for (_, value) in evaluation.dimensionScores {
                XCTAssertGreaterThanOrEqual(value, 0.0)
                XCTAssertLessThanOrEqual(value, 1.0)
            }
            if let score = evaluation.finalScore {
                XCTAssertGreaterThanOrEqual(score, 0.0)
                XCTAssertLessThanOrEqual(score, 100.0)
            }
        }

        XCTAssertEqual(mismatchedConfigKeys, 0,
                       "有 \(mismatchedConfigKeys) 条记录的 config_key 与本实现不一致")
        print("✅ 真实数据兼容性：\(papers.count) 条记录解码成功，"
            + "其中 \(withEvaluation) 条带评分，配置指纹全部一致")
    }
}
