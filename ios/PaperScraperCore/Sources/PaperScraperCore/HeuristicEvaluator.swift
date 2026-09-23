//
//  HeuristicEvaluator.swift
//  PaperScraperCore
//
//  启发式评分内核：`evaluator.HeuristicEvaluator` 的 Swift 移植。
//
//  移植纪律
//  --------
//  这个文件里的每个分支都必须与 Python 一一对应，包括看起来"不必要"的部分：
//
//    * **先算原始分、最后才 round**：Python 输出里 `dimension_scores` 是四舍五入
//      过的，但综合分用的是**未四舍五入**的原始分。顺序反了分数就会漂移。
//    * **累加顺序固定**：`dimensionOrder` 必须等于 Python dict 的插入顺序，
//      否则浮点求和的结合律差异会体现在末位。
//    * **子串匹配而非分词**：`title` 维度用的是 `w in t`（子串），不是词匹配；
//      而 `topic` 维度用的是带词边界的 `\\b...\\b`。两者不同，不能混用。
//

import Foundation

public struct HeuristicEvaluator: Sendable {

    /// 默认权重。键与 `evaluator.HeuristicEvaluator.DEFAULT_WEIGHTS` 一致。
    public static let defaultWeights: [String: Double] = [
        "title": 0.20,
        "author": 0.20,
        "abstract": 0.15,
        "recency": 0.15,
        "topic": 0.30,
    ]

    /// 加权求和的固定顺序。
    ///
    /// ⚠️ 必须与 Python `dict(self.weights)` 的插入顺序一致：
    /// 浮点加法不满足结合律，求和顺序会改变综合分的最低位。
    public static let dimensionOrder = ["title", "author", "abstract", "recency", "topic"]

    /// venue 出现时从各维度匀出的权重比例。
    public static let venueWeightShift = 0.10

    /// institution 出现时从各维度匀出的权重比例。
    ///
    /// 与 venue 用同样的 0.10，并且**在 venue 之后**再匀一次：
    /// 两个维度同时出现时，原有五维会被乘两次 (1 - 0.10)。
    /// Python 侧的顺序与数值必须完全一致。
    public static let institutionWeightShift = 0.10

    /// 归一化后的权重（和为 1）。
    public let weights: [String: Double]

    public init(weights: [String: Double]? = nil) {
        let base = weights ?? Self.defaultWeights
        // 按固定顺序求和，与 Python `sum(self.weights.values())` 一致
        let total = Self.dimensionOrder.reduce(0.0) { $0 + (base[$1] ?? 0) }
        precondition(total > 0, "weights must sum to a positive value")

        var normalized: [String: Double] = [:]
        for key in Self.dimensionOrder {
            guard let value = base[key] else { continue }
            normalized[key] = value / total
        }
        self.weights = normalized
    }

    // MARK: - 维度评分

    /// 标题质量：长度区间、冒号、方法词、问号、模板短语惩罚。
    public func titleScore(_ title: String) -> Double {
        if title.isEmpty || title == "N/A" { return 0.0 }
        let lowered = title.lowercased()
        var score = 0.5

        let wordCount = PyCompat.splitWhitespace(title).count
        if (8...20).contains(wordCount) {
            score += 0.20
        } else if (5..<8).contains(wordCount) || (21...25).contains(wordCount) {
            score += 0.10
        }

        if title.contains(":") { score += 0.10 }
        // 注意：Python 用 `w in t` 做子串匹配，不是词匹配
        if Keywords.titleMethodWords.contains(where: { lowered.contains($0) }) {
            score += 0.10
        }
        if PyCompat.strip(title).hasSuffix("?") { score += 0.05 }
        if Keywords.titleTemplatePhrases.contains(where: { lowered.contains($0) }) {
            score -= 0.05
        }
        return min(1.0, max(0.0, score))
    }

    /// 作者信号：人数、机构关键词、et al。
    public func authorScore(_ authors: String) -> Double {
        if authors.isEmpty || authors == "N/A" { return 0.2 }
        let lowered = authors.lowercased()
        var score = 0.5

        let names = authors
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { PyCompat.strip(String($0)) }
            .filter { !$0.isEmpty }

        let count = names.count
        if (2...8).contains(count) {
            score += 0.20
        } else if count == 1 {
            score -= 0.10
        } else if count > 15 {
            score -= 0.05
        }

        if lowered.contains("et al") { score -= 0.05 }
        if Keywords.institutionKeywords.contains(where: { lowered.contains($0) }) {
            score += 0.20
        }
        return min(1.0, max(0.0, score))
    }

    /// 摘要信息量：长度、方法词、结果词、数字指标。
    public func abstractScore(_ abstract: String) -> Double {
        if abstract.isEmpty || abstract == "N/A" { return 0.0 }
        let lowered = abstract.lowercased()
        let length = PyCompat.length(abstract)
        var score = 0.0

        if (500...2000).contains(length) {
            score += 0.30
        } else if (200..<500).contains(length) || (2001...3000).contains(length) {
            score += 0.20
        } else if length > 100 {
            score += 0.10
        }

        let methodHits = Keywords.abstractMethodWords.filter { lowered.contains($0) }.count
        score += methodHits >= 2 ? 0.20 : (methodHits == 1 ? 0.10 : 0.0)

        let resultHits = Keywords.abstractResultWords.filter { lowered.contains($0) }.count
        score += resultHits >= 2 ? 0.20 : (resultHits == 1 ? 0.10 : 0.0)

        // 数字指标在**原始大小写**上匹配（对齐 Python 把 abstract 原串传进 re）
        if KeywordMatcher.containsPercentPattern(abstract) { score += 0.15 }
        if KeywordMatcher.containsMultiplierPattern(abstract) { score += 0.10 }
        if Keywords.abstractSignalWords.contains(where: { lowered.contains($0) }) {
            score += 0.10
        }
        return min(1.0, max(0.0, score))
    }

    /// 时效性：按距今天数分段线性衰减。
    public func recencyScore(_ submissionTime: String, today: Date? = nil) -> Double {
        guard let submitted = PyCompat.parseISODate(submissionTime) else { return 0.3 }

        var days = PyCompat.daysBetween(submitted, today ?? Date())
        if days < 0 { days = 0 }

        if days <= 30 { return 1.0 }
        if days <= 90 { return 1.0 - Double(days - 30) / 60.0 * 0.5 }
        if days <= 365 { return 0.5 - Double(days - 90) / 275.0 * 0.3 }
        return 0.2
    }

    /// 主题热度：`1 - exp(-Σw / 2)`。
    public func topicScore(_ text: String) -> Double {
        if text.isEmpty { return 0.0 }
        let lowered = text.lowercased()

        var total = 0.0
        // 必须按 topicKeywords 的声明顺序累加（浮点加法不满足结合律）
        for entry in Keywords.topicKeywords where
            KeywordMatcher.matches(entry.keyword, in: lowered) {
            total += entry.weight
        }
        return 1.0 - exp(-total / 2.0)
    }

    /// 发表场所：仅在出现发表信号时返回分值，否则返回 nil（该维度不参与）。
    public func venueScore(_ text: String) -> Double? {
        if text.isEmpty { return nil }
        let lowered = text.lowercased()

        let hasSignal = Keywords.venueSignalWords.contains { lowered.contains($0) }
        guard hasSignal else { return nil }

        var score = 0.0
        if Keywords.venueTopTier.contains(where: { lowered.contains($0) }) {
            score = max(score, 0.9)
        }
        if Keywords.venueWorkshop.contains(where: { lowered.contains($0) }) {
            score = max(score, 0.5)
        }
        return score == 0.0 ? 0.3 : score
    }

    /// 作者机构：**仅在真的拿到机构信息时**返回分值，否则 nil（该维度不参与）。
    ///
    /// 为什么和 `venueScore` 一样做成"有条件参与"
    /// ----------------------------------------
    /// 机构名不在 arXiv 的 API 响应里，要么解析 HTML 的作者块、要么查 Semantic
    /// Scholar，都依赖网络。已经落盘的历史记录里没有这个数据，如果让它无条件参与，
    /// 所有旧记录的分都会变，`config_key` 语义也会被搞乱。
    /// 做成"有数据才参与"后：**没有机构信息的论文评分完全不变**，
    /// 既有的 91 条金标准对拍与 150 条历史记录全部保持逐位一致。
    ///
    /// 代价要说清楚：有机构和没机构的论文分数**可比性变弱**（多了一个加权维度）。
    /// 这一点与既有的 `venue` 维度是同一类取舍，故保持一致。
    ///
    /// - Returns: 1.0 档 / 0.85 档 / 0.5（有机构但不在名单里）；空数组返回 nil。
    public func institutionScore(_ institutions: [String]) -> Double? {
        guard !institutions.isEmpty else { return nil }

        // 逐档取最高分：一篇论文可能同时有多个机构，取最好的那个
        var best = 0.0
        for institution in institutions {
            let lowered = institution.lowercased()
            if Keywords.institutionTopTier.contains(where: {
                KeywordMatcher.matches($0, in: lowered)
            }) {
                best = max(best, 1.0)
            } else if Keywords.institutionStrongTier.contains(where: {
                KeywordMatcher.matches($0, in: lowered)
            }) {
                best = max(best, 0.85)
            }
        }
        // 有机构信息但不在名单里：给中性分而不是 0，
        // 否则"没收录的机构"会被当成"机构差"，而名单本身必然是不全的
        return best == 0 ? 0.5 : best
    }

    // MARK: - 综合

    /// 计算各维度分并加权求和，返回 0~100 的综合分。
    ///
    /// - Parameters:
    ///   - institutions: 作者机构名（来自 arXiv HTML 的作者块或 Semantic Scholar）。
    ///     为空时"机构"维度不参与，评分与不带该维度时完全相同。
    ///   - today: 注入"今天"以便复现；默认取当前时间。
    public func evaluate(_ paper: Paper, institutions: [String] = [],
                         today: Date? = nil) -> Evaluation {
        let textAll = "\(paper.title) \(paper.abstract)"

        var dims: [String: Double] = [:]
        dims["title"] = titleScore(paper.title)
        dims["author"] = authorScore(paper.authors)
        dims["abstract"] = abstractScore(paper.abstract)
        dims["recency"] = recencyScore(paper.submissionTime, today: today)
        dims["topic"] = topicScore(textAll)

        // ⚠️ 下面两个"有条件参与"的维度，追加顺序必须与 Python 一致：
        // venue 先、institution 后。求和时按同一顺序累加，浮点结果才会逐位相同。
        var weights = self.weights
        var dimensionKeys = Self.dimensionOrder
        if let venue = venueScore(textAll) {
            dims["venue"] = venue
            let shift = Self.venueWeightShift
            for key in dimensionKeys {
                if let value = weights[key] { weights[key] = value * (1 - shift) }
            }
            weights["venue"] = shift
            dimensionKeys.append("venue")
        }
        if let institution = institutionScore(institutions) {
            dims["institution"] = institution
            let shift = Self.institutionWeightShift
            for key in dimensionKeys {
                if let value = weights[key] { weights[key] = value * (1 - shift) }
            }
            weights["institution"] = shift
            dimensionKeys.append("institution")
        }

        // ⚠️ 用**未四舍五入**的原始分求和，顺序见 dimensionOrder 注释
        var final = 0.0
        var roundedWeights: [String: Double] = [:]
        var roundedDims: [String: Double] = [:]
        for key in dimensionKeys {
            if let dim = dims[key], let weight = weights[key] {
                final += dim * weight
            }
            if let weight = weights[key] { roundedWeights[key] = PyCompat.round(weight, 3) }
            if let dim = dims[key] { roundedDims[key] = PyCompat.round(dim, 3) }
        }

        return Evaluation(
            dimensionScores: roundedDims,
            weights: roundedWeights,
            finalScore: PyCompat.round(final * 100, 2)
        )
    }
}
