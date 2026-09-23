//
//  ArxivClient.swift
//  PaperScraperCore
//
//  arXiv 官方 Atom API 客户端（`retriever.py` 的 Swift 对应实现）。
//
//  为什么不是"照搬 requests + BeautifulSoup"
//  -----------------------------------------
//  原实现抓的是 arxiv.org 的搜索结果页，依赖 `li.arxiv-result` 这类未公开承诺
//  的类名（详见项目 README 的变更记录）。换成官方 Atom API 后：
//
//    * 返回结构化 XML，页面改版不再导致解析全线失败；
//    * 时间戳自带 ISO 8601，不需要手写月份名映射表；
//    * 官方支持 `start` / `max_results` 分页（旧实现单页封顶约 50 条）。
//
//  移动端特有的三条约束
//  --------------------
//  1. **必须有超时**。旧实现没有 timeout，弱网下会一直挂着；在 iOS 后台刷新那
//     约 30 秒的预算里等于直接卡死。
//  2. **必须串行 + 限速**。用 `actor` 保证同一时刻只有一个请求在飞，
//     并在两次请求之间保持 `minInterval`（默认 3 秒）间隔。
//  3. **必须可取消**。每次循环检查 `Task.isCancelled`，让"用户划走 App"能立刻
//     停止网络活动，而不是拖到超时。
//

import Foundation

// MARK: - 请求参数

public struct ArxivQuery: Sendable {
    public var query: String
    /// 最多抓取条数；`nil` 表示不限（谨慎使用）。
    public var maxResults: Int?
    /// 起始偏移，用于续抓。
    public var start: Int
    /// `true` 按提交时间倒序；`false` 走相关度（与 Python 默认行为一致）。
    public var sortBySubmittedDate: Bool
    /// 分页时单页条数。
    public var pageSize: Int

    public init(query: String,
                maxResults: Int? = 50,
                start: Int = 0,
                sortBySubmittedDate: Bool = false,
                pageSize: Int = 100) {
        self.query = query
        self.maxResults = maxResults
        self.start = start
        self.sortBySubmittedDate = sortBySubmittedDate
        self.pageSize = pageSize
    }
}

public enum ArxivError: LocalizedError, Sendable {
    case emptyQuery
    case invalidRequest
    case httpStatus(Int)
    case unexpectedResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: "搜索关键词为空"
        case .invalidRequest: "无法构造请求地址"
        case .httpStatus(let code): "arXiv 返回 HTTP \(code)"
        case .unexpectedResponse: "arXiv 返回了无法识别的响应"
        case .cancelled: "请求已取消"
        }
    }
}

// MARK: - 客户端

public actor ArxivClient {

    /// 官方 Atom API 端点。
    public static let endpoint = URL(string: "https://export.arxiv.org/api/query")!

    /// 描述性 User-Agent：对齐 arXiv 对 API 使用者的要求，便于对方定位来源。
    /// 高频使用者建议在 App 设置里补上联系方式。
    public static let defaultUserAgent = "new-paper-scraper/1.0 (iOS; arXiv Atom API client)"

    /// 需要重试的状态码（与 Python 侧 RETRY_STATUS 一致）。
    public static let retryableStatus: Set<Int> = [429, 500, 502, 503, 504]

    private let session: URLSession
    private let userAgent: String
    private let minInterval: TimeInterval
    private let maxRetries: Int
    private let backoff: TimeInterval

    private var lastRequestAt: Date?

    /// - Parameters:
    ///   - timeout: 单次请求超时（秒）。
    ///   - minInterval: 两次请求之间的最小间隔（秒）。
    ///   - maxRetries: 失败重试次数（指数退避）。
    public init(userAgent: String = ArxivClient.defaultUserAgent,
                timeout: TimeInterval = 30,
                minInterval: TimeInterval = 3.0,
                maxRetries: Int = 3,
                backoff: TimeInterval = 2.0) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        // 后台刷新预算有限：连不上就尽快失败，不要一直等网络恢复
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        self.session = URLSession(configuration: configuration)
        self.userAgent = userAgent
        self.minInterval = max(0, minInterval)
        self.maxRetries = max(0, maxRetries)
        self.backoff = max(1.0, backoff)
    }

    // MARK: 抓取

    /// 按关键词抓取论文；超过单页上限时自动分页。
    public func fetchPapers(_ options: ArxivQuery) async throws -> [Paper] {
        let query = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ArxivError.emptyQuery }

        var papers: [Paper] = []
        var seen = Set<String>()
        var cursor = max(0, options.start)
        var remaining = options.maxResults.map { max(0, $0) }
        let pageSize = max(1, options.pageSize)

        while remaining == nil || (remaining ?? 0) > 0 {
            try Task.checkCancellation()

            let size = remaining.map { min(pageSize, $0) } ?? pageSize
            guard size > 0 else { break }

            var items = [
                URLQueryItem(name: "search_query", value: "all:\(query)"),
                URLQueryItem(name: "start", value: String(cursor)),
                URLQueryItem(name: "max_results", value: String(size)),
            ]
            if options.sortBySubmittedDate {
                items.append(URLQueryItem(name: "sortBy", value: "submittedDate"))
                items.append(URLQueryItem(name: "sortOrder", value: "descending"))
            }

            let data = try await performRequest(items)
            let batch = AtomFeedParser.parse(data)
            if batch.isEmpty { break }

            for paper in batch where seen.insert(paper.url).inserted {
                papers.append(paper)
            }

            cursor += batch.count
            if let left = remaining { remaining = left - batch.count }
            if batch.count < size { break }  // 已到结果末尾
        }

        return papers
    }

    // MARK: 网络

    private func performRequest(_ items: [URLQueryItem]) async throws -> Data {
        guard var components = URLComponents(url: Self.endpoint,
                                             resolvingAgainstBaseURL: false) else {
            throw ArxivError.invalidRequest
        }
        components.queryItems = items
        guard let url = components.url else { throw ArxivError.invalidRequest }

        var lastError: Error = ArxivError.invalidRequest

        for attempt in 0...maxRetries {
            try Task.checkCancellation()
            await throttle()

            do {
                let (data, response) = try await session.data(from: url)
                lastRequestAt = Date()
                guard let http = response as? HTTPURLResponse else {
                    throw ArxivError.unexpectedResponse
                }
                if Self.retryableStatus.contains(http.statusCode) {
                    throw ArxivError.httpStatus(http.statusCode)
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw ArxivError.httpStatus(http.statusCode)
                }
                return data
            } catch is CancellationError {
                throw ArxivError.cancelled
            } catch {
                lastError = error
                guard attempt < maxRetries, Self.isRetryable(error) else { break }
                let delay = pow(backoff, Double(attempt))
                try? await Task.sleep(for: .seconds(delay))
            }
        }

        throw lastError
    }

    /// 保证两次请求之间至少间隔 `minInterval` 秒。
    private func throttle() async {
        guard minInterval > 0, let last = lastRequestAt else { return }
        let elapsed = Date().timeIntervalSince(last)
        let wait = minInterval - elapsed
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case ArxivError.httpStatus(let code) = error {
            return retryableStatus.contains(code)
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .resourceUnavailable, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}

// MARK: - Atom 解析

/// 把 Atom XML 解析为论文列表。逻辑与 Python `retriever.parse_atom` 一一对应。
public enum AtomFeedParser {

    public static func parse(_ data: Data) -> [Paper] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return [] }
        return delegate.papers
    }

    /// - Note: `XMLParserDelegate` 的回调是同步的，delegate 生命周期与 `parse()`
    ///   完全重合，因此这里不需要考虑并发安全。
    final class Delegate: NSObject, XMLParserDelegate {

        private(set) var papers: [Paper] = []

        private var insideEntry = false
        private var textBuffer = ""

        private var title = ""
        private var summary = ""
        private var published = ""
        private var identifier = ""
        private var alternate = ""
        private var authors: [String] = []

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            textBuffer = ""
            let name = elementName.lowercased()

            switch name {
            case "entry":
                insideEntry = true
                title = ""; summary = ""; published = ""
                identifier = ""; alternate = ""; authors = []
            case "link" where insideEntry:
                if attributeDict["rel"] == "alternate",
                   let href = attributeDict["href"], !href.isEmpty {
                    alternate = href
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard insideEntry else { return }
            textBuffer += string
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            let text = textBuffer
            textBuffer = ""
            guard insideEntry else { return }

            switch elementName.lowercased() {
            case "title": title = text
            case "summary": summary = text
            case "published": published = text
            case "id": if identifier.isEmpty { identifier = text }
            case "name": authors.append(text)
            case "entry":
                insideEntry = false
                papers.append(Paper(
                    title: PyCompat.collapseWhitespace(title).isEmpty
                        ? "N/A" : PyCompat.collapseWhitespace(title),
                    authors: normalizedAuthors(),
                    url: normalizedURL(),
                    abstract: normalizedAbstract(),
                    submissionTime: normalizedDate()
                ))
            default:
                break
            }
        }

        // ---- 字段归一化 ----

        private func normalizedAuthors() -> String {
            let names = authors
                .map { PyCompat.collapseWhitespace($0) }
                .filter { !$0.isEmpty }
            return names.isEmpty ? "N/A" : names.joined(separator: ", ")
        }

        private func normalizedAbstract() -> String {
            var text = PyCompat.collapseWhitespace(summary)
            if text.lowercased().hasPrefix("abstract:") {
                text = String(text.dropFirst("abstract:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return text.isEmpty ? "N/A" : text
        }

        /// 归一化为 `https://arxiv.org/abs/<id>`，并**去掉版本号后缀 vN**。
        ///
        /// 去版本号是关键：`papers_metadata.json` 里的既有记录都不带版本号，
        /// 否则去重会全部失效。
        private func normalizedURL() -> String {
            let href = alternate.isEmpty ? identifier : alternate
            guard let range = href.range(of: "arxiv.org/abs/",
                                         options: .caseInsensitive) else {
                return "N/A"
            }

            var rest = String(href[range.upperBound...])
            if let cut = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                rest = String(rest[..<cut])
            }
            if let versionIndex = rest.lastIndex(where: { $0 == "v" || $0 == "V" }) {
                let suffix = rest[rest.index(after: versionIndex)...]
                if !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) {
                    rest = String(rest[..<versionIndex])
                }
            }
            return rest.isEmpty ? "N/A" : "https://arxiv.org/abs/" + rest
        }

        /// `<published>` 形如 `2025-06-07T17:59:59Z` -> `2025-06-07`。
        private func normalizedDate() -> String {
            let cleaned = PyCompat.collapseWhitespace(published)
            guard cleaned.count >= 10 else { return "N/A" }
            let head = String(cleaned.prefix(10))
            let parts = head.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  parts[0].count == 4, parts[0].allSatisfy({ $0.isNumber }),
                  parts[1].count == 2, parts[1].allSatisfy({ $0.isNumber }),
                  parts[2].count == 2, parts[2].allSatisfy({ $0.isNumber })
            else { return "N/A" }
            return head
        }
    }
}
