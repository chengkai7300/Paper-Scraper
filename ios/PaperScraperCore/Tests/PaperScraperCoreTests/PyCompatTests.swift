//
//  PyCompatTests.swift
//  PaperScraperCoreTests
//
//  验证"CPython 语义兼容层"确实等价于 Python，而不是"差不多"。
//  这些断言里的期望值都是从 CPython 实测得到的。
//

import XCTest
@testable import PaperScraperCore

final class PyCompatTests: XCTestCase {

    // MARK: - round（半偶进位）

    func testRoundUsesBankersRounding() {
        // Python: round(0.5) == 0, round(1.5) == 2, round(2.5) == 2
        XCTAssertEqual(PyCompat.round(0.5, 0), 0.0)
        XCTAssertEqual(PyCompat.round(1.5, 0), 2.0)
        XCTAssertEqual(PyCompat.round(2.5, 0), 2.0)

        // Swift 原生的 (x*1000).rounded()/1000 在下面两个用例上会给出 0.063 / 0.188
        XCTAssertEqual(PyCompat.round(0.0625, 3), 0.062)
        XCTAssertEqual(PyCompat.round(0.1875, 3), 0.188)

        // 常规路径
        XCTAssertEqual(PyCompat.round(0.9916666666666667, 3), 0.992)
        XCTAssertEqual(PyCompat.round(51.784999999999997, 2), 51.78)
        XCTAssertEqual(PyCompat.round(0.06666666666666667, 6), 0.066667)
    }

    func testFloatReprMatchesPythonJsonOutput() {
        XCTAssertEqual(PyCompat.floatRepr(0.2), "0.2")
        XCTAssertEqual(PyCompat.floatRepr(1.0), "1.0")
        XCTAssertEqual(PyCompat.floatRepr(0.0), "0.0")
        XCTAssertEqual(PyCompat.floatRepr(0.15), "0.15")
        XCTAssertEqual(PyCompat.floatRepr(0.066667), "0.066667")
        XCTAssertEqual(PyCompat.floatRepr(0.333333), "0.333333")
    }

    // MARK: - 字符串

    func testLengthCountsUnicodeScalarsNotGraphemes() {
        // Python: len("e\u{0301}") == 2，而 Swift 的 String.count == 1
        let combining = "e\u{0301}"
        XCTAssertEqual(PyCompat.length(combining), 2)
        XCTAssertEqual(combining.count, 1)

        XCTAssertEqual(PyCompat.length("中文摘要"), 4)
        XCTAssertEqual(PyCompat.length(""), 0)
    }

    func testSplitAndCollapseWhitespace() {
        // Python: "a\xa0b".split() == ["a", "b"]
        XCTAssertEqual(PyCompat.splitWhitespace("a\u{a0}b"), ["a", "b"])
        XCTAssertEqual(PyCompat.splitWhitespace("  a \n b\t c "), ["a", "b", "c"])
        XCTAssertEqual(PyCompat.splitWhitespace(""), [])
        XCTAssertEqual(PyCompat.collapseWhitespace("  a \n  b  "), "a b")
    }

    // MARK: - 哈希

    func testSha1MatchesPythonHashlib() {
        // hashlib.sha1(b"abc").hexdigest()
        XCTAssertEqual(PyCompat.sha1Hex("abc"),
                       "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(PyCompat.sha1Hex("abc", prefix: 12), "a9993e364706")
        XCTAssertEqual(PyCompat.sha1Hex("中文"), PyCompat.sha1Hex("中文"))
        XCTAssertNotEqual(PyCompat.sha1Hex("中文"), PyCompat.sha1Hex("英文"))
    }

    // MARK: - 日期

    func testParseISODateMatchesStrptime() {
        XCTAssertNotNil(PyCompat.parseISODate("2026-09-01"))
        // Python 的 %m/%d 允许 1~2 位
        XCTAssertNotNil(PyCompat.parseISODate("2026-9-1"))
        // Python 会校验日期真实存在
        XCTAssertNil(PyCompat.parseISODate("2026-02-30"))
        XCTAssertNil(PyCompat.parseISODate("2026-13-01"))
        XCTAssertNil(PyCompat.parseISODate("N/A"))
        XCTAssertNil(PyCompat.parseISODate(""))
        XCTAssertNil(PyCompat.parseISODate("2026/09/01"))
    }

    func testDaysBetweenUsesCalendarDays() throws {
        let from = try XCTUnwrap(PyCompat.parseISODate("2026-09-01"))
        let to = try XCTUnwrap(PyCompat.parseISODate("2026-09-22"))
        XCTAssertEqual(PyCompat.daysBetween(from, to), 21)
        XCTAssertEqual(PyCompat.daysBetween(to, from), -21)
        XCTAssertEqual(PyCompat.daysBetween(from, from), 0)
    }

    // MARK: - 关键词词边界

    func testKeywordMatcherWordBoundaries() {
        // 命中
        XCTAssertTrue(KeywordMatcher.matches("llm", in: "llms"))
        XCTAssertTrue(KeywordMatcher.matches("llm", in: "  llm  "))
        XCTAssertTrue(KeywordMatcher.matches("multi-agent", in: "multi-agents"))
        XCTAssertTrue(KeywordMatcher.matches("cot", in: "cot"))
        XCTAssertTrue(KeywordMatcher.matches("graph", in: "graph"))

        // 不应命中（词内子串）
        XCTAssertFalse(KeywordMatcher.matches("llm", in: "xllm"))
        XCTAssertFalse(KeywordMatcher.matches("llm", in: "llmx"))
        XCTAssertFalse(KeywordMatcher.matches("cot", in: "scotland"))
        XCTAssertFalse(KeywordMatcher.matches("graph", in: "paragraph"))
        XCTAssertFalse(KeywordMatcher.matches("rag", in: "storage"))
        XCTAssertFalse(KeywordMatcher.matches("asr", in: "laser"))

        // 中文相邻时，Python 的 \b 也不成立（中文字符属于 \w）
        XCTAssertFalse(KeywordMatcher.matches("llm", in: "大语言模型的llm能力"))
    }

    // MARK: - 数字指标的正则等价实现

    func testPercentPattern() {
        XCTAssertTrue(KeywordMatcher.containsPercentPattern("improve by 12.5%"))
        XCTAssertTrue(KeywordMatcher.containsPercentPattern("improve by 12 %"))
        XCTAssertTrue(KeywordMatcher.containsPercentPattern("gain 100%"))
        XCTAssertFalse(KeywordMatcher.containsPercentPattern(".%"))
        XCTAssertFalse(KeywordMatcher.containsPercentPattern("12."))
        XCTAssertFalse(KeywordMatcher.containsPercentPattern("%"))
        XCTAssertFalse(KeywordMatcher.containsPercentPattern("no numbers here"))
    }

    func testMultiplierPattern() {
        XCTAssertTrue(KeywordMatcher.containsMultiplierPattern("3.5x faster"))
        XCTAssertTrue(KeywordMatcher.containsMultiplierPattern("3 times faster"))
        XCTAssertTrue(KeywordMatcher.containsMultiplierPattern("2 fold"))
        XCTAssertTrue(KeywordMatcher.containsMultiplierPattern("4x"))
        // 正则没有右边界，所以 "10xTRA" 也命中
        XCTAssertTrue(KeywordMatcher.containsMultiplierPattern("10xTRA"))
        XCTAssertTrue(KeywordMatcher.containsMultiplierPattern("SPEEDUP 4X"))

        // 这两个是 Python 正则的真实行为，不是实现缺陷：
        //   * "2-fold" 中间有连字符，`\s*` 匹配不到它，因此不命中；
        //   * "many times" 前面没有数字。
        XCTAssertFalse(KeywordMatcher.containsMultiplierPattern("2-fold cheaper"))
        XCTAssertFalse(KeywordMatcher.containsMultiplierPattern("x faster"))
        XCTAssertFalse(KeywordMatcher.containsMultiplierPattern("many times"))
    }
}
