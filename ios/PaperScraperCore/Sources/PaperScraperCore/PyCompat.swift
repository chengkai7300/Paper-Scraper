//
//  PyCompat.swift
//  PaperScraperCore
//
//  CPython 语义兼容层。
//
//  为什么需要这一层
//  ----------------
//  移植要求"两端对同一篇论文给出完全相同的分数"，而 Swift 与 Python 在若干
//  细节上的默认行为不同。这些差异都会真实影响到分数，必须在底层抹平：
//
//   1. `round()` —— Python 是**半偶进位**（banker's rounding），Swift 的
//      `rounded()` 是"半远离零"。在 .5 处会差一个最小单位。
//   2. `len(str)` —— Python 按 **Unicode 码点**计数，Swift 的 `String.count`
//      按**字素簇**计数，遇到组合字符或 emoji 时不一致。
//   3. `str.split()` / `str.strip()` —— 空白字符集合与折叠方式需对齐。
//   4. `hashlib.sha1(...).hexdigest()` —— 哈希算法与编码一致即可，但必须显式
//      指定 UTF-8。
//   5. `regex \\b` —— Python 的 `\\w` 是 Unicode 字母数字 + 下划线，Swift 用
//      `Character` 的 `isLetter/isNumber` 等价实现（见 KeywordMatcher）。
//   6. `date.today()` / `(d1 - d2).days` —— 需要按**本地日历日**求差，而非
//      按 86400 秒整除。
//

import CryptoKit
import Foundation

public enum PyCompat {

    // MARK: - 数值

    /// 等价于 Python 的 `round(x, digits)`：半偶进位。
    ///
    /// 实现分两步，缺一不可：
    ///   1. 把 double 的最短可往返十进制表示交给 `NSDecimalRound(.bankers)`；
    ///   2. **再用十进制字符串解析回 Double**（`Double(String)` 走 strtod，
    ///      是正确舍入的）。
    ///
    /// 第 2 步不能换成 `NSDecimalNumber.doubleValue` —— 后者只保证"近似"，
    /// 实测 `round(0.13333333333333333, 6)` 会得到 0.13333299999999998
    /// （repr 差一个 ULP），而 Python 得到 0.133333。
    public static func round(_ x: Double, _ digits: Int) -> Double {
        guard x.isFinite else { return x }
        var source = Decimal(string: String(x), locale: nil) ?? Decimal(x)
        var result = Decimal()
        NSDecimalRound(&result, &source, digits, .bankers)

        if let exact = Double(result.description) { return exact }
        return NSDecimalNumber(decimal: result).doubleValue
    }

    /// 等价于 Python `json.dumps` 输出 float 的形式（最短可往返表示）。
    ///
    /// 用于构造 `config_key` 的指纹载荷 —— 必须与 Python 逐字节一致，
    /// 否则与既有历史记录的指纹对不上。
    public static func floatRepr(_ x: Double) -> String {
        String(x)
    }

    // MARK: - 字符串

    /// 等价于 Python 的 `len(str)`：按 Unicode 码点计数。
    public static func length(_ s: String) -> Int {
        s.unicodeScalars.count
    }

    /// 等价于 Python 的 `str.split()`：按空白切分，丢弃空串。
    public static func splitWhitespace(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// 等价于 Python 的 `" ".join(s.split())`：折叠所有空白为单个空格。
    public static func collapseWhitespace(_ s: String) -> String {
        splitWhitespace(s).joined(separator: " ")
    }

    /// 等价于 Python 的 `str.strip()`。
    public static func strip(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 哈希

    /// 等价于 Python 的 `hashlib.sha1(s.encode("utf-8")).hexdigest()`。
    ///
    /// - Parameter prefix: 只取前 N 个十六进制字符（Python 侧用 `[:12]` / `[:16]`）。
    public static func sha1Hex(_ s: String, prefix: Int? = nil) -> String {
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard let prefix else { return hex }
        return String(hex.prefix(prefix))
    }

    // MARK: - 日期

    /// 等价于 Python 的 `date.isoformat()`（本地日历）。
    public static func isoDateString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 等价于 Python 的 `datetime.strptime(text, "%Y-%m-%d").date()`。
    ///
    /// 与 CPython 保持一致的两个宽容点：
    ///   * 月 / 日允许 1~2 位（`2026-9-1` 可解析）；
    ///   * 会校验日期真实存在（`2026-02-30` 返回 nil）。
    public static func parseISODate(_ text: String,
                                    calendar: Calendar = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = digitsToInt(parts[0], allowedLengths: 1...4),
              let month = digitsToInt(parts[1], allowedLengths: 1...2),
              let day = digitsToInt(parts[2], allowedLengths: 1...2)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }

        // Calendar 会把 2026-02-30 规范化成 2026-03-02，需回读校验
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else {
            return nil
        }
        return date
    }

    /// 等价于 Python 的 `(d1 - d2).days`：按本地日历日之差。
    public static func daysBetween(_ from: Date, _ to: Date,
                                   calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    // MARK: - 字符分类（对齐 Python re 的 \\w / \\d / \\s）

    /// 等价于 Python 正则 `\\w`（`str.isalnum()` 或下划线）。
    public static func isWordCharacter(_ c: Character) -> Bool {
        c == "_" || c.isLetter || c.isNumber
    }

    /// 等价于 Python 正则 `\\d`（Unicode 十进制数字）。
    public static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.decimalDigits.contains(scalar)
    }

    /// 等价于 Python 正则 `\\s`。
    public static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func digitsToInt(_ sub: Substring,
                                    allowedLengths: ClosedRange<Int>) -> Int? {
        guard allowedLengths.contains(sub.count) else { return nil }
        guard sub.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(sub)
    }
}

// MARK: - 关键词匹配

public enum KeywordMatcher {

    /// 等价于 Python 的 `re.search(r"\\b" + re.escape(keyword) + r"s?\\b", text)`。
    ///
    /// 这里刻意**不用** `NSRegularExpression`：关键词里有 `-` 和空格，Python 的
    /// `re.escape` 会把它们转义成 `\\-` / `\\ `，而 ICU 对这类转义的接受度与
    /// Python 不一致。改为手工实现"词边界 + 可选复数 s"，语义可一一对应：
    ///
    ///   * `\\b` 等价于：匹配位置的相邻字符不是 `\\w`（或已在串首/串尾）；
    ///   * `s?` 等价于：先尝试不带 s，再尝试带 s。
    ///
    /// - Note: 传入的 `text` 应已由调用方小写（与 Python `_topic_score` 一致）。
    public static func matches(_ keyword: String, in text: String) -> Bool {
        let haystack = Array(text.lowercased())
        let base = Array(keyword.lowercased())
        guard !base.isEmpty, haystack.count >= base.count else { return false }

        for candidate in [base, base + ["s"]] {
            var start = 0
            while start + candidate.count <= haystack.count {
                if Array(haystack[start..<(start + candidate.count)]) == candidate {
                    let beforeOK = start == 0
                        || !PyCompat.isWordCharacter(haystack[start - 1])
                    let end = start + candidate.count
                    let afterOK = end == haystack.count
                        || !PyCompat.isWordCharacter(haystack[end])
                    if beforeOK && afterOK { return true }
                }
                start += 1
            }
        }
        return false
    }

    /// 等价于 Python 的 `re.search(r"\\d+(\\.\\d+)?\\s*%", text)`。
    ///
    /// 存在性等价于："存在一个 `%`，其**前一个非空白字符是数字**"。
    /// 理由：正则要求 `\\d+` 之后（可跨空白）紧跟 `%`；反过来说若 `%` 前面
    /// （跳过空白）就是数字，则 `\\d+` 匹配该数字、可选小数部分为空即可成立。
    public static func containsPercentPattern(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        for index in scalars.indices where scalars[index] == "%" {
            var back = index - 1
            while back >= 0 && PyCompat.isSpace(scalars[back]) { back -= 1 }
            if back >= 0 && PyCompat.isDigit(scalars[back]) { return true }
        }
        return false
    }

    /// 等价于 Python 的
    /// `re.search(r"\\d+(\\.\\d+)?\\s*(x|fold|times)", text, re.IGNORECASE)`。
    ///
    /// 与百分比同理：存在 `x` / `fold` / `times` 的某个出现位置，其前一个
    /// 非空白字符是数字。（正则无后置约束，故 `3.5x` 也能在 `3.5xTRA` 中命中。）
    public static func containsMultiplierPattern(_ text: String) -> Bool {
        let scalars = Array(text.lowercased().unicodeScalars)
        for token in Keywords.multiplierTokens {
            let needle = Array(token.unicodeScalars)
            guard !needle.isEmpty, scalars.count >= needle.count else { continue }
            var start = 0
            while start + needle.count <= scalars.count {
                if Array(scalars[start..<(start + needle.count)]) == needle {
                    var back = start - 1
                    while back >= 0 && PyCompat.isSpace(scalars[back]) { back -= 1 }
                    if back >= 0 && PyCompat.isDigit(scalars[back]) { return true }
                }
                start += 1
            }
        }
        return false
    }
}
