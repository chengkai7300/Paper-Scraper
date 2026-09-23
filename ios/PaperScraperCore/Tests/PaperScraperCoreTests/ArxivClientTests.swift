//
//  ArxivClientTests.swift
//  PaperScraperCoreTests
//
//  Atom 解析与 URL 归一化的离线测试（不联网）。
//

import XCTest
@testable import PaperScraperCore

final class AtomFeedParserTests: XCTestCase {

    private let sampleFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <link href="http://arxiv.org/api/query?search_query=all:LLM" rel="self" type="application/atom+xml"/>
      <title type="html">ArXiv Query: search_query=all:LLM</title>
      <id>http://arxiv.org/api/abcdef</id>
      <updated>2026-09-22T00:00:00-04:00</updated>
      <entry>
        <id>http://arxiv.org/abs/2506.06962v1</id>
        <updated>2025-06-08T00:00:00Z</updated>
        <published>2025-06-07T17:59:59Z</published>
        <title>AR-RAG: Autoregressive Retrieval Augmentation for Image Generation</title>
        <summary>  We introduce Autoregressive Retrieval Augmentation (AR-RAG), a
    novel paradigm that enhances image generation.
        </summary>
        <author><name>Jingyuan Qi</name></author>
        <author><name>Zhiyang Xu</name></author>
        <link href="http://arxiv.org/abs/2506.06962v1" rel="alternate" type="text/html"/>
        <link title="pdf" href="http://arxiv.org/pdf/2506.06962v1" rel="related" type="application/pdf"/>
      </entry>
      <entry>
        <id>http://arxiv.org/abs/2402.12317v3</id>
        <published>2024-02-19T10:00:00Z</published>
        <title>Abstract: Prefixed Title</title>
        <summary>Abstract: A short one.</summary>
        <author><name>Alice</name></author>
        <link href="http://arxiv.org/abs/2402.12317v3" rel="alternate" type="text/html"/>
      </entry>
    </feed>
    """

    private func parsed() -> [Paper] {
        AtomFeedParser.parse(Data(sampleFeed.utf8))
    }

    func testParsesAllEntries() {
        XCTAssertEqual(parsed().count, 2)
    }

    func testNormalizesFields() throws {
        let first = try XCTUnwrap(parsed().first)

        XCTAssertEqual(first.title,
                       "AR-RAG: Autoregressive Retrieval Augmentation for Image Generation")
        XCTAssertEqual(first.authors, "Jingyuan Qi, Zhiyang Xu")
        // 版本号后缀 v1 必须被去掉，否则与历史记录去重会失效
        XCTAssertEqual(first.url, "https://arxiv.org/abs/2506.06962")
        XCTAssertEqual(first.abstract,
                       "We introduce Autoregressive Retrieval Augmentation (AR-RAG), "
                       + "a novel paradigm that enhances image generation.")
        XCTAssertEqual(first.submissionTime, "2025-06-07")
    }

    func testStripsAbstractPrefix() throws {
        let second = try XCTUnwrap(parsed().last)
        XCTAssertEqual(second.abstract, "A short one.")
        XCTAssertEqual(second.url, "https://arxiv.org/abs/2402.12317")
    }

    func testFeedLevelElementsAreIgnored() throws {
        // feed 自身的 <title>/<id> 不能被当成第一篇文章
        let titles = parsed().map(\.title)
        XCTAssertFalse(titles.contains { $0.contains("ArXiv Query") })
    }

    func testMalformedXMLReturnsEmpty() {
        XCTAssertTrue(AtomFeedParser.parse(Data("<feed><entry>".utf8)).isEmpty)
        XCTAssertTrue(AtomFeedParser.parse(Data()).isEmpty)
    }

    /// PDF 直链由摘要页链接推导，与 Python `main.py` 的 `/abs/` -> `/pdf/` 一致。
    func testPDFURLDerivation() throws {
        let first = try XCTUnwrap(parsed().first)
        XCTAssertEqual(first.pdfURL?.absoluteString,
                       "https://arxiv.org/pdf/2506.06962")
    }

    func testPDFFileNameSanitization() throws {
        let paper = Paper(title: "AR-RAG: Autoregressive/Retrieval \"Augmentation\"?",
                          authors: "A", url: "u", abstract: "", submissionTime: "N/A")
        // 只保留字母数字与空格/_/-
        XCTAssertEqual(paper.pdfFileName, "AR-RAG AutoregressiveRetrieval Augmentation.pdf")
    }
}

// MARK: - 存储

final class PaperStoreTests: XCTestCase {

    func testRoundTripPreservesEvaluation() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("paper-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(PaperStore.defaultFileName)

        let today = PyCompat.parseISODate("2026-09-22")!
        let evaluator = PaperEvaluator()
        var paper = Paper(title: "Sparse Kernels: A Benchmark",
                          authors: "Ada Lovelace, Alan Turing, Google",
                          url: "https://arxiv.org/abs/2609.00001",
                          abstract: "Accepted at NeurIPS 2026. "
                              + String(repeating: "q", count: 600),
                          submissionTime: "2026-09-10")
        paper.evaluation = evaluator.evaluate(paper, today: today)

        try PaperStore.save([paper], to: url)
        let loaded = try PaperStore.load(from: url)

        XCTAssertEqual(loaded.count, 1)
        let restored = try XCTUnwrap(loaded.first)
        XCTAssertEqual(restored.title, paper.title)
        XCTAssertEqual(restored.abstract, paper.abstract)
        XCTAssertEqual(restored.submissionTime, "2026-09-10")
        XCTAssertEqual(restored.evaluation?.configKey, paper.evaluation?.configKey)
        XCTAssertEqual(restored.evaluation?.contentHash, paper.evaluation?.contentHash)
        XCTAssertEqual(restored.evaluation?.finalScore, paper.evaluation?.finalScore)
        XCTAssertEqual(restored.evaluation?.dimensionScores,
                       paper.evaluation?.dimensionScores)
    }

    /// Python 会写入 `"external": null`，Swift 侧必须保持同一形态。
    func testNilEnrichmentIsEncodedAsNull() throws {
        let evaluator = PaperEvaluator()
        var paper = Paper(title: "T", authors: "A", url: "u",
                          abstract: "", submissionTime: "N/A")
        paper.evaluation = evaluator.evaluate(paper)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try XCTUnwrap(String(data: try encoder.encode(paper),
                                       encoding: .utf8))
        XCTAssertTrue(json.contains("\"external\":null"), "external 应编码为 null：\(json)")
        XCTAssertTrue(json.contains("\"llm\":null"), "llm 应编码为 null：\(json)")
    }

    func testLoadReturnsEmptyForMissingFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        XCTAssertEqual(try PaperStore.load(from: url).count, 0)
    }

    func testLooseDecodingToleratesMissingFields() throws {
        let json = """
        [{"title": "Only A Title"}, {"url": "https://arxiv.org/abs/1", "abstract": null}]
        """
        let papers = try JSONDecoder().decode([Paper].self, from: Data(json.utf8))
        XCTAssertEqual(papers.count, 2)
        XCTAssertEqual(papers[0].title, "Only A Title")
        XCTAssertEqual(papers[0].authors, "N/A")
        XCTAssertEqual(papers[1].abstract, "N/A")
        XCTAssertEqual(papers[1].submissionTime, "N/A")
    }
}
