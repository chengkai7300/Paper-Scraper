//
//  Enrichment.swift
//  PaperScraperCore
//
//  可选的两层增强：`evaluator.ExternalEnricher` 与 `evaluator.LLMEvaluator` 的
//  Swift 移植。两者都默认关闭，只影响**最终分**，不改变任何维度的原始分。
//
//  Python 侧是同步阻塞实现；这里改为 `async`，让调用方可以并发、可以取消，
//  这是移动端必须的（后台刷新预算只有约 30 秒）。
//

import Foundation

// MARK: - 外部引用信号

public struct ExternalSignals: Sendable, Hashable {
    public var citationCount: Int
    public var influentialCitationCount: Int
    public var venue: String?
    public var year: Int?
    public var authorHIndexAvg: Double
    public var hfUpvotes: Int?
    /// 0~100 的外部混合分。
    public var externalScore: Double

    public init(citationCount: Int,
                influentialCitationCount: Int,
                venue: String?,
                year: Int?,
                authorHIndexAvg: Double,
                hfUpvotes: Int?,
                externalScore: Double) {
        self.citationCount = citationCount
        self.influentialCitationCount = influentialCitationCount
        self.venue = venue
        self.year = year
        self.authorHIndexAvg = authorHIndexAvg
        self.hfUpvotes = hfUpvotes
        self.externalScore = externalScore
    }

    /// 与 Python `enrich()` 返回的 dict 保持同名字段。
    public func jsonValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "citationCount": .number(Double(citationCount)),
            "influentialCitationCount": .number(Double(influentialCitationCount)),
            "author_h_index_avg": .number(authorHIndexAvg),
            "external_score": .number(externalScore),
        ]
        object["venue"] = venue.map { .string($0) } ?? .null
        object["year"] = year.map { .number(Double($0)) } ?? .null
        object["hf_upvotes"] = hfUpvotes.map { .number(Double($0)) } ?? .null
        return .object(object)
    }
}

/// Semantic Scholar 引用量 / 作者 h-index + HuggingFace 点赞量。
public actor ExternalEnricher {

    private let timeout: TimeInterval
    private var cache: [String: ExternalSignals?] = [:]

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    /// 从 url 中提取 arXiv ID（与 Python `extract_arxiv_id` 等价）。
    public static func arxivID(from url: String) -> String? {
        guard let range = url.range(of: "arxiv.org/abs/", options: .caseInsensitive) else {
            return nil
        }
        var rest = String(url[range.upperBound...])
        if let cut = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = String(rest[..<cut])
        }
        return rest.isEmpty ? nil : rest
    }

    public func enrich(_ paper: Paper) async -> ExternalSignals? {
        guard let arxivID = Self.arxivID(from: paper.url) else { return nil }
        if let cached = cache[arxivID] { return cached }

        let semanticScholar = await fetchSemanticScholar(arxivID)
        let citations = semanticScholar?.citationCount ?? 0
        let influential = semanticScholar?.influentialCitationCount ?? 0
        let hIndexAverage = semanticScholar?.authorHIndexAverage ?? 0

        // external_score = (0.7 * citation + 0.3 * h) * 100
        //   citation = min(1, log1p(c) / log1p(1000))
        //   h        = min(1, h_avg / 50)
        let citationScore = min(1.0, log1p(Double(citations)) / log1p(1000))
        let hScore = min(1.0, hIndexAverage / 50.0)
        let externalScore = (0.7 * citationScore + 0.3 * hScore) * 100

        let upvotes = await fetchHuggingFaceUpvotes(arxivID)

        let signals = ExternalSignals(
            citationCount: citations,
            influentialCitationCount: influential,
            venue: semanticScholar?.venue,
            year: semanticScholar?.year,
            authorHIndexAvg: PyCompat.round(hIndexAverage, 2),
            hfUpvotes: upvotes,
            externalScore: PyCompat.round(externalScore, 2))

        cache[arxivID] = signals
        return signals
    }

    // MARK: 私有

    private struct SemanticScholarResult {
        var citationCount: Int
        var influentialCitationCount: Int
        var venue: String?
        var year: Int?
        var authorHIndexAverage: Double
    }

    private func fetchSemanticScholar(_ arxivID: String) async -> SemanticScholarResult? {
        let fields = "title,citationCount,influentialCitationCount,venue,year,"
            + "authors.name,authors.hIndex,authors.affiliations"
        guard let url = URL(string:
            "https://api.semanticscholar.org/graph/v1/paper/arXiv:\(arxivID)")
        else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "fields", value: fields)]
        guard let finalURL = components?.url else { return nil }

        guard let data = await get(finalURL) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let authors = (root["authors"] as? [[String: Any]]) ?? []
        let hIndices = authors.compactMap { $0["hIndex"] as? Double }.filter { $0 != 0 }
        let average = hIndices.isEmpty ? 0 : hIndices.reduce(0, +) / Double(hIndices.count)

        return SemanticScholarResult(
            citationCount: (root["citationCount"] as? Double).map(Int.init) ?? 0,
            influentialCitationCount: (root["influentialCitationCount"] as? Double)
                .map(Int.init) ?? 0,
            venue: root["venue"] as? String,
            year: (root["year"] as? Double).map(Int.init),
            authorHIndexAverage: average)
    }

    private func fetchHuggingFaceUpvotes(_ arxivID: String) async -> Int? {
        guard let url = URL(string: "https://huggingface.co/api/papers/\(arxivID)") else {
            return nil
        }
        guard let data = await get(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (root["upvotes"] as? Double).map(Int.init)
    }

    private func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("new-paper-scraper/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return data
        } catch {
            return nil  // 增强失败不影响主流程，与 Python 的 try/except 行为一致
        }
    }
}

// MARK: - LLM 语义评分

public struct LLMResult: Sendable, Hashable {
    public var raw: [String: Double]
    /// 五维均分换算到 0~100。
    public var llmScore: Double

    public init(raw: [String: Double], llmScore: Double) {
        self.raw = raw
        self.llmScore = llmScore
    }

    public func jsonValue() -> JSONValue {
        .object([
            "raw": .object(raw.mapValues { .number($0) }),
            "llm_score": .number(llmScore),
        ])
    }
}

public struct LLMEvaluator: Sendable {

    /// 与 Python `LLMEvaluator.DEFAULT_PROMPT` 逐字一致。
    public static let defaultPrompt = """
    You are an expert reviewer. Given the title and abstract of an arXiv \
    paper, rate it on five dimensions from 0 to 10 (integers):
    1. novelty
    2. technical_rigor
    3. clarity
    4. potential_impact
    5. relevance_to_hot_topics
    Return ONLY a JSON object with these five keys.

    Title: {title}

    Abstract: {abstract}
    """

    public let baseURL: String
    public let model: String
    public let timeout: TimeInterval

    public init(baseURL: String = "https://api.openai.com/v1",
                model: String = "gpt-4o-mini",
                timeout: TimeInterval = 30) {
        self.baseURL = baseURL.hasSuffix("/")
            ? String(baseURL.dropLast()) : baseURL
        self.model = model
        self.timeout = timeout
    }

    /// - Parameter apiKey: 由 App 从 Keychain 取出后传入（不落盘、不进代码库）。
    public func evaluate(_ paper: Paper, apiKey: String) async -> LLMResult? {
        guard !apiKey.isEmpty else { return nil }

        let abstract = String(paper.abstract.prefix(4000))
        let prompt = Self.defaultPrompt
            .replacingOccurrences(of: "{title}", with: paper.title)
            .replacingOccurrences(of: "{abstract}", with: abstract)

        guard let url = URL(string: "\(baseURL)/chat/completions") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.0,
            "response_format": ["type": "json_object"],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else { return nil }

            guard let scoresData = content.data(using: .utf8),
                  let scores = try? JSONSerialization.jsonObject(with: scoresData)
                    as? [String: Any]
            else { return nil }

            let numeric = scores.compactMapValues { value -> Double? in
                if let double = value as? Double { return double }
                if let int = value as? Int { return Double(int) }
                if let string = value as? String { return Double(string) }
                return nil
            }
            guard !numeric.isEmpty else { return nil }

            // Python: sum(...) / max(1, len(scores))
            let average = numeric.values.reduce(0, +) / Double(max(1, numeric.count))
            return LLMResult(raw: numeric,
                             llmScore: PyCompat.round(average * 10, 2))
        } catch {
            return nil
        }
    }
}
