//
//  PaperEvaluator.swift
//  PaperScraperCore
//
//  组合评估器：`evaluator.PaperEvaluator` 的 Swift 移植。
//
//  与 Python 的差异（有意为之）
//  --------------------------
//  Python 的 `evaluate()` 在内部同步发起 HTTP 请求（Semantic Scholar /
//  HuggingFace / LLM）。Swift 侧网络必须是异步的，所以这里**拆成两段**：
//
//    * `evaluate(_:today:)` —— 纯启发式，同步、可复现、与 golden 对拍；
//    * `applying(...)`     —— 把外部分 / LLM 分按权重混入最终分。
//
//  调用方（App 层）负责先异步取回外部数据，再调用 `applying`。
//  这样纯函数部分保持可测试，网络部分保持可取消、可并发。
//

import Foundation

public struct PaperEvaluator: Sendable {

    public let heuristic: HeuristicEvaluator
    /// 是否启用 Semantic Scholar / HuggingFace 增强（影响配置指纹）。
    public let useExternal: Bool
    /// LLM 语义评分是否实际可用（未配置 Key 时为 false）。
    public let llmEnabled: Bool
    public let externalWeight: Double
    public let llmWeight: Double

    public init(weights: [String: Double]? = nil,
                useExternal: Bool = false,
                llmEnabled: Bool = false,
                externalWeight: Double = 0.20,
                llmWeight: Double = 0.30) {
        self.heuristic = HeuristicEvaluator(weights: weights)
        self.useExternal = useExternal
        self.llmEnabled = llmEnabled
        self.externalWeight = externalWeight
        self.llmWeight = llmWeight
    }

    // MARK: - 配置指纹

    /// 评分配置指纹。
    ///
    /// ⚠️ 必须与 Python `PaperEvaluator.config_key` **逐字节**一致：
    /// 历史记录里存的就是这个值，不一致会导致既有记录全部被判为"配置已变更"。
    ///
    /// Python 侧的实现是
    /// `sha1(json.dumps(payload, sort_keys=True, ensure_ascii=False))[:12]`，
    /// 其中 `json.dumps` 的默认分隔符是 `", "` 与 `": "`，浮点用最短往返表示，
    /// 权重先 `round(v, 6)`。因此这里手工拼串而不是用 JSONEncoder —— 
    /// JSONEncoder 的键序、分隔符与浮点格式都无法保证与之相同。
    public var configKey: String {
        PyCompat.sha1Hex(configKeyPayload, prefix: 12)
    }

    /// 指纹的原文载荷。单独暴露出来是为了让对拍测试能直接展示差异
    /// （只比对 sha1 的话，不一致时完全看不出是哪个字段的问题）。
    public var configKeyPayload: String {
        let weightsJSON = heuristic.weights
            .map { ($0.key, PyCompat.round($0.value, 6)) }
            .sorted { $0.0 < $1.0 }
            .map { "\"\($0.0)\": \(PyCompat.floatRepr($0.1))" }
            .joined(separator: ", ")

        return "{\"external\": \(useExternal ? "true" : "false"), "
            + "\"external_weight\": \(PyCompat.floatRepr(externalWeight)), "
            + "\"llm\": \(llmEnabled ? "true" : "false"), "
            + "\"llm_weight\": \(PyCompat.floatRepr(llmWeight)), "
            + "\"weights\": {\(weightsJSON)}}"
    }

    // MARK: - 评分

    /// 纯启发式评分（不含外部增强），并补齐溯源字段。
    ///
    /// 注意 `external` / `llm` 被显式写成 `.null`：Python 侧会写入
    /// `"external": null`，写成 Swift 的 `nil` 会让键直接消失，破坏文件可比性。
    ///
    /// - Parameter institutions: 作者机构名。为空时"机构"维度不参与，
    ///   评分与不带该维度时逐位相同（金标准与历史记录的兼容性依赖这一点）。
    public func evaluate(_ paper: Paper, institutions: [String] = [],
                         today: Date? = nil) -> Evaluation {
        var result = heuristic.evaluate(paper, institutions: institutions, today: today)
        let base = result.finalScore ?? 0
        result.baseScore = PyCompat.round(base, 2)
        result.external = .null
        result.llm = .null
        result.configKey = configKey
        result.contentHash = Self.contentHash(paper)
        result.evaluatedOn = PyCompat.isoDateString(today ?? Date())
        return result
    }

    /// 把外部增强分与 LLM 分按权重混入最终分（对应 Python 里的两段 `final = ...`）。
    ///
    /// - Parameters:
    ///   - externalScore: Semantic Scholar + HuggingFace 混合后的 0~100 分。
    ///   - llmScore: LLM 五维均分换算后的 0~100 分。
    public func applying(_ evaluation: Evaluation,
                         externalScore: Double? = nil,
                         externalRaw: JSONValue? = nil,
                         llmScore: Double? = nil,
                         llmRaw: JSONValue? = nil) -> Evaluation {
        var result = evaluation
        var final = evaluation.finalScore ?? 0

        result.external = externalRaw ?? .null
        if let externalScore {
            let weight = externalWeight
            final = final * (1 - weight) + externalScore * weight
        }

        result.llm = llmRaw ?? .null
        if let llmScore {
            let weight = llmWeight
            final = final * (1 - weight) + llmScore * weight
        }

        result.finalScore = PyCompat.round(final, 2)
        return result
    }

    // MARK: - 内容指纹

    /// 参与评分的文本字段指纹。
    ///
    /// 对齐 Python `paper_content_hash`：字段顺序固定，
    /// 缺失或为 nil 的字段视作空串，用 `\u{1F}` 连接后取 sha1 前 16 位。
    public static func contentHash(_ paper: Paper) -> String {
        contentHash(title: paper.title,
                    authors: paper.authors,
                    abstract: paper.abstract,
                    submissionTime: paper.submissionTime)
    }

    /// 四字段版本：便于直接对"缺字段/值为 null"的原始 JSON 求指纹。
    ///
    /// ⚠️ 缺失与 null 都必须视作**空字符串**（而不是 "N/A"），
    /// 否则会与 Python 的 `paper.get(k) or ""` 口径不一致。
    public static func contentHash(title: String,
                                   authors: String,
                                   abstract: String,
                                   submissionTime: String) -> String {
        let payload = [title, authors, abstract, submissionTime]
            .joined(separator: "\u{1F}")
        return PyCompat.sha1Hex(payload, prefix: 16)
    }

    // MARK: - 排序

    /// 按综合分降序排序，并把评分写回论文对象。
    ///
    /// Python 的 `list.sort` 是**稳定排序**（同分保持原顺序），Swift 的 `sort`
    /// 不保证稳定，因此这里显式把原始下标作为第二排序键。
    public func rank(_ papers: [Paper], today: Date? = nil)
        -> [(score: Double, paper: Paper)] {
        var scored: [(index: Int, score: Double, paper: Paper)] = []
        for (index, original) in papers.enumerated() {
            var paper = original
            let evaluation = evaluate(paper, today: today)
            paper.evaluation = evaluation
            scored.append((index, evaluation.finalScore ?? 0, paper))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }
        return scored.map { (score: $0.score, paper: $0.paper) }
    }
}
