//
//  Models.swift
//  PaperScraperCore
//
//  数据模型：与 Python 侧 `papers_metadata.json` 的字段一一对应。
//
//  兼容性目标
//  ----------
//  同一个 `papers_metadata.json` 应能在 Python 工具与 iOS App 之间来回传递。
//  因此这里的 JSON 键名、可空性、缺省值都严格对齐 Python 的输出：
//    * 键名用 snake_case（submission_time / dimension_scores / final_score ...）
//    * `external` / `llm` 结构不固定（可能是 dict 或 null），用 JSONValue 承载
//    * 读取时对缺字段/类型不符保持宽容，避免老记录导致整体解码失败
//

import Foundation

// MARK: - 任意 JSON 值

/// 结构不固定的 JSON 值。
///
/// Python 侧 `evaluation.external` / `evaluation.llm` 在未启用增强时为 `null`，
/// 启用后是任意嵌套结构，因此需要一个能无损往返的容器。
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "不支持的 JSON 值")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// 从对象里取一个标量数字字段；不是对象、键不存在或值不是数字时返回 nil。
    ///
    /// 用途：重新评分时把已存的增强分读回来，避免"重算一次就把用户开启的
    /// 外部增强 / LLM 效果抹掉"。
    public func scalarScore(forKey key: String) -> Double? {
        guard case .object(let fields) = self, case .number(let value)? = fields[key]
        else { return nil }
        return value
    }
}

// MARK: - 评分结果

/// 一条论文记录里的 `evaluation` 字段。
public struct Evaluation: Codable, Sendable, Hashable {

    /// 各维度原始分（0~1）。`venue` 仅在文本出现发表信号时才存在。
    public var dimensionScores: [String: Double]
    /// 实际参与加权的权重（venue 出现时会重新分配）。
    public var weights: [String: Double]
    /// 综合分 0~100（叠加外部/LLM 之后）。
    public var finalScore: Double?
    /// 仅启发式部分的综合分。
    public var baseScore: Double?
    /// `--external` 的原始结果，未启用为 nil。
    public var external: JSONValue?
    /// `--llm` 的原始结果，未启用为 nil。
    public var llm: JSONValue?
    /// 评分配置指纹（增量评价的判据之一）。
    public var configKey: String?
    /// 参与评分文本字段的指纹。
    public var contentHash: String?
    /// 评分日期 YYYY-MM-DD。
    public var evaluatedOn: String?

    /// 维度展示顺序，与 Python 的输出顺序一致。
    public static let orderedDimensionKeys = [
        "title", "author", "abstract", "recency", "topic", "venue",
    ]

    public init(dimensionScores: [String: Double] = [:],
                weights: [String: Double] = [:],
                finalScore: Double? = nil,
                baseScore: Double? = nil,
                external: JSONValue? = nil,
                llm: JSONValue? = nil,
                configKey: String? = nil,
                contentHash: String? = nil,
                evaluatedOn: String? = nil) {
        self.dimensionScores = dimensionScores
        self.weights = weights
        self.finalScore = finalScore
        self.baseScore = baseScore
        self.external = external
        self.llm = llm
        self.configKey = configKey
        self.contentHash = contentHash
        self.evaluatedOn = evaluatedOn
    }

    enum CodingKeys: String, CodingKey {
        case dimensionScores = "dimension_scores"
        case weights
        case finalScore = "final_score"
        case baseScore = "base_score"
        case external
        case llm
        case configKey = "config_key"
        case contentHash = "content_hash"
        case evaluatedOn = "evaluated_on"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dimensionScores = Self.decodeScoreMap(container, .dimensionScores)
        weights = Self.decodeScoreMap(container, .weights)
        finalScore = try? container.decodeIfPresent(Double.self, forKey: .finalScore)
        baseScore = try? container.decodeIfPresent(Double.self, forKey: .baseScore)
        external = try? container.decodeIfPresent(JSONValue.self, forKey: .external)
        llm = try? container.decodeIfPresent(JSONValue.self, forKey: .llm)
        configKey = try? container.decodeIfPresent(String.self, forKey: .configKey)
        contentHash = try? container.decodeIfPresent(String.self, forKey: .contentHash)
        evaluatedOn = try? container.decodeIfPresent(String.self, forKey: .evaluatedOn)
    }

    /// 解码 `{"title": 0.9, "venue": null}` 这类字典：丢弃 null，忽略类型异常的项。
    private static func decodeScoreMap(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> [String: Double] {
        guard let raw = try? container.decode([String: Double?].self, forKey: key) else {
            return [:]
        }
        return raw.compactMapValues { $0 }
    }
}

// MARK: - 论文

/// 一篇论文的元数据 + 评分。字段与 `papers_metadata.json` 中的对象一致。
public struct Paper: Codable, Sendable, Hashable, Identifiable {

    public var title: String
    public var authors: String
    public var url: String
    public var abstract: String
    public var submissionTime: String
    public var evaluation: Evaluation?

    /// 去重键。Python 侧同样以 url 作为唯一标识。
    public var id: String { url.isEmpty ? title : url }

    public init(title: String,
                authors: String,
                url: String,
                abstract: String,
                submissionTime: String,
                evaluation: Evaluation? = nil) {
        self.title = title
        self.authors = authors
        self.url = url
        self.abstract = abstract
        self.submissionTime = submissionTime
        self.evaluation = evaluation
    }

    enum CodingKeys: String, CodingKey {
        case title
        case authors
        case url
        case abstract
        case submissionTime = "submission_time"
        case evaluation
    }

    /// 宽容解码：缺字段或类型异常时回落到 `"N/A"`，与抓取层的约定一致。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = Self.decodeString(container, .title)
        authors = Self.decodeString(container, .authors)
        url = Self.decodeString(container, .url)
        abstract = Self.decodeString(container, .abstract)
        submissionTime = Self.decodeString(container, .submissionTime)
        evaluation = try? container.decodeIfPresent(Evaluation.self, forKey: .evaluation)
    }

    private static func decodeString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> String {
        // decodeIfPresent 返回 String?，配合 try? 展平后仍为 String?：
        // 键缺失与值为 null 都会走到 "N/A"
        guard let value = try? container.decodeIfPresent(String.self, forKey: key) else {
            return "N/A"
        }
        return value
    }

    /// PDF 直链由摘要页链接推导（与 Python `executor.py` 的做法一致）。
    public var pdfURL: URL? {
        guard url.contains("/abs/") else { return nil }
        return URL(string: url.replacingOccurrences(of: "/abs/", with: "/pdf/"))
    }

    /// PDF 文件名：与 Python 侧 `main.py` 的清洗规则保持一致。
    public var pdfFileName: String {
        let allowed = title.filter { $0.isLetter || $0.isNumber || " _-".contains($0) }
        let trimmed = allowed.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let head = trimmed.count > 100 ? String(trimmed.prefix(100)) : trimmed
        return head.isEmpty ? "paper.pdf" : "\(head).pdf"
    }
}

// MARK: - 评分档位

/// 一条可对比的评分快照（用于回溯前后的差异报告）。
public struct ScoreSnapshot: Sendable, Hashable {
    public var score: Double
    public var dims: [String: Double]

    public init(score: Double, dims: [String: Double]) {
        self.score = score
        self.dims = dims
    }
}
