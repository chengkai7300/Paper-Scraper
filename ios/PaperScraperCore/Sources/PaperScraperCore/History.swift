//
//  History.swift
//  PaperScraperCore
//
//  历史回溯 / 增量评价 / 前后对比：`history.py` 的 Swift 移植。
//
//  这一层完全是纯函数式逻辑（只依赖 json / os / shutil / datetime 的对应能力），
//  因此可以 1:1 移植，也是本次移植中"零风险"的部分。
//

import Foundation

// MARK: - 失效原因

public enum StalenessReason: String, Sendable, CaseIterable {
    case missing
    case configChanged = "config_changed"
    case contentChanged = "content_changed"
    case recencyExpired = "recency_expired"
    case forced

    /// 与 Python `REASON_LABELS` 一致的中文说明。
    public var label: String {
        switch self {
        case .missing: "缺少历史评分"
        case .configChanged: "权重/配置已变更"
        case .contentChanged: "论文内容已变更"
        case .recencyExpired: "时效性需刷新（跨天）"
        case .forced: "强制执行"
        }
    }
}

/// 维度中文名，与 Python `DIM_LABELS` 一致。
public enum DimensionLabels {
    public static let map: [String: String] = [
        "title": "标题",
        "author": "作者",
        "abstract": "摘要",
        "recency": "时效",
        "topic": "主题",
        "venue": "场所",
        "institution": "机构",
    ]

    public static func label(_ key: String) -> String { map[key] ?? key }

    /// 全部维度，按报告与设置页需要的稳定顺序排列。
    ///
    /// `venue` / `institution` 是**有条件参与**的维度（无数据时整体缺席），
    /// 但它们同样是合法的展示项，所以一并列出。
    public static let allKeys = [
        "title", "author", "abstract", "recency", "topic",
        "venue", "institution",
    ]
}

// MARK: - 结果类型

public struct ReevaluationStats: Sendable {
    public var total: Int = 0
    public var reevaluated: Int = 0
    public var skipped: Int = 0
    public var reasons: [StalenessReason: Int] = [:]
    public var missingBefore: Int = 0
    /// 历史记录中出现过的旧权重（格式化后的字符串，已排序）。
    public var oldWeightSets: [String] = []
}

public struct ReevaluationResult: Sendable {
    public var stats: ReevaluationStats
    public var before: [ScoreSnapshot?]
    public var after: [ScoreSnapshot?]
}

public struct ComparisonEntry: Sendable, Hashable {
    public var title: String
    public var url: String
    public var beforeScore: Double
    public var afterScore: Double
    public var scoreDelta: Double
    public var beforeRank: Int
    public var afterRank: Int
    /// >0 表示名次上升。
    public var rankDelta: Int
}

public struct DimensionDelta: Sendable, Hashable {
    public var dimension: String
    public var before: Double
    public var after: Double
    public var delta: Double { after - before }
}

public struct Comparison: Sendable {
    public var comparable: Int = 0
    public var changed: Int = 0
    public var changedRatio: Double = 0
    public var meanDelta: Double = 0
    public var meanAbsDelta: Double = 0
    public var maxUp: ComparisonEntry?
    public var maxDown: ComparisonEntry?
    public var entries: [ComparisonEntry] = []
    public var topN: Int = 10
    public var topOverlap: Int = 0
    public var topBefore: [ComparisonEntry] = []
    public var topAfter: [ComparisonEntry] = []
    public var spearman: Double = 1.0
    public var moversUp: [ComparisonEntry] = []
    public var moversDown: [ComparisonEntry] = []
    public var dimDeltas: [DimensionDelta] = []
}

public struct HistoryRunResult: Sendable {
    public var stats: ReevaluationStats
    public var comparison: Comparison
    public var report: String
}

// MARK: - 历史模块

public enum History {

    // MARK: 增量判据

    /// 取出记录中可用的评分（没有有效 final_score 时返回 nil）。
    public static func storedEvaluation(_ paper: Paper) -> Evaluation? {
        guard let evaluation = paper.evaluation, evaluation.finalScore != nil else {
            return nil
        }
        return evaluation
    }

    /// 历史评分是否与当前评分配置"同口径"。
    ///
    /// 新记录直接比对 `config_key`；老记录没有指纹，退化为比对权重
    /// （venue 是运行时动态加入的维度，不参与比对）。
    public static func configMatches(_ stored: Evaluation,
                                     evaluator: PaperEvaluator) -> Bool {
        if let key = stored.configKey {
            return key == evaluator.configKey
        }

        let current = evaluator.heuristic.weights
        let legacy = stored.weights.filter { $0.key != "venue" }
        guard !legacy.isEmpty, Set(legacy.keys) == Set(current.keys) else {
            return false
        }
        for (key, value) in current {
            guard let old = legacy[key], abs(old - value) < 5e-3 else { return false }
        }
        return true
    }

    /// 判断历史评分是否失效；未失效返回 nil。
    public static func stalenessReason(_ paper: Paper,
                                       evaluator: PaperEvaluator,
                                       today: Date? = nil) -> StalenessReason? {
        guard let stored = storedEvaluation(paper) else { return .missing }

        if !configMatches(stored, evaluator: evaluator) { return .configChanged }

        if let storedHash = stored.contentHash,
           storedHash != PaperEvaluator.contentHash(paper) {
            return .contentChanged
        }

        let stamp = PyCompat.isoDateString(today ?? Date())
        if stored.evaluatedOn != stamp { return .recencyExpired }
        return nil
    }

    // MARK: 排名与相关系数

    /// 把 `{下标: 分数}` 转为 `{下标: 名次}`，同分按下标升序稳定排列。
    public static func rankScores(_ scores: [Int: Double]) -> [Int: Int] {
        let ordered = scores
            .map { (index: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
        var ranks: [Int: Int] = [:]
        for (position, item) in ordered.enumerated() {
            ranks[item.index] = position + 1
        }
        return ranks
    }

    /// 无第三方依赖的 Spearman 秩相关系数。
    public static func spearman(_ rankA: [Double], _ rankB: [Double]) -> Double {
        let n = rankA.count
        if n < 2 { return 1.0 }

        let meanA = rankA.reduce(0, +) / Double(n)
        let meanB = rankB.reduce(0, +) / Double(n)

        var covariance = 0.0
        for (a, b) in zip(rankA, rankB) {
            covariance += (a - meanA) * (b - meanB)
        }
        let varianceA = rankA.reduce(0.0) { $0 + ($1 - meanA) * ($1 - meanA) }.squareRoot()
        let varianceB = rankB.reduce(0.0) { $0 + ($1 - meanB) * ($1 - meanB) }.squareRoot()

        if varianceA != 0 && varianceB != 0 {
            return covariance / (varianceA * varianceB)
        }
        return 1.0
    }

    // MARK: 增量重评

    /// 按需增量重算历史评分，并返回前后快照。`papers` 会被就地更新。
    ///
    /// - Parameter institutions: 提供作者机构的回调（按论文返回）。
    ///   ⚠️ 必须传：机构是"有条件参与"的维度，不传的话重评会把已经并入的
    ///   机构维度丢掉，那些论文的分数会悄悄退回旧口径。
    public static func reevaluateHistory(_ papers: inout [Paper],
                                         evaluator: PaperEvaluator,
                                         force: Bool = false,
                                         today: Date? = nil,
                                         institutions: ((Paper) -> [String])? = nil)
        -> ReevaluationResult {
        let resolvedToday = today ?? Date()
        var stats = ReevaluationStats()
        stats.total = papers.count

        var before = [ScoreSnapshot?](repeating: nil, count: papers.count)
        var after = [ScoreSnapshot?](repeating: nil, count: papers.count)
        var oldWeightSets = Set<String>()

        for index in papers.indices {
            let paper = papers[index]
            let stored = storedEvaluation(paper)

            if let stored, let score = stored.finalScore {
                before[index] = ScoreSnapshot(score: score, dims: stored.dimensionScores)
                if !stored.weights.isEmpty {
                    oldWeightSets.insert(formatWeights(stored.weights))
                }
            } else {
                stats.missingBefore += 1
            }

            let reason: StalenessReason? = force
                ? .forced
                : stalenessReason(paper, evaluator: evaluator, today: resolvedToday)

            guard let reason else {
                stats.skipped += 1
                if let snapshot = before[index] {
                    after[index] = snapshot
                }
                continue
            }

            stats.reasons[reason, default: 0] += 1
            let fresh = evaluator.evaluate(paper,
                                           institutions: institutions?(paper) ?? [],
                                           today: resolvedToday)
            papers[index].evaluation = fresh
            stats.reevaluated += 1
            after[index] = ScoreSnapshot(score: fresh.finalScore ?? 0,
                                        dims: fresh.dimensionScores)
        }

        stats.oldWeightSets = oldWeightSets.sorted()
        return ReevaluationResult(stats: stats, before: before, after: after)
    }

    // MARK: 前后对比

    public static func compareBeforeAfter(_ papers: [Paper],
                                          before: [ScoreSnapshot?],
                                          after: [ScoreSnapshot?],
                                          topN: Int = 10) -> Comparison {
        var comparison = Comparison()
        comparison.topN = topN

        let indices = papers.indices.filter { before[$0] != nil && after[$0] != nil }
        guard !indices.isEmpty else { return comparison }

        var beforeScores: [Int: Double] = [:]
        var afterScores: [Int: Double] = [:]
        for index in indices {
            beforeScores[index] = before[index]!.score
            afterScores[index] = after[index]!.score
        }

        let beforeRank = rankScores(beforeScores)
        let afterRank = rankScores(afterScores)

        var deltas: [Int: Double] = [:]
        var rankDeltas: [Int: Int] = [:]
        for index in indices {
            deltas[index] = afterScores[index]! - beforeScores[index]!
            rankDeltas[index] = beforeRank[index]! - afterRank[index]!  // >0 名次上升
        }

        func entry(_ index: Int) -> ComparisonEntry {
            ComparisonEntry(
                title: papers[index].title,
                url: papers[index].url,
                beforeScore: beforeScores[index]!,
                afterScore: afterScores[index]!,
                scoreDelta: deltas[index]!,
                beforeRank: beforeRank[index]!,
                afterRank: afterRank[index]!,
                rankDelta: rankDeltas[index]!
            )
        }

        // ---- 维度平均分变化（只统计前后都存在的维度）----
        var dimensionKeys = Set<String>()
        for index in indices {
            dimensionKeys.formUnion(before[index]!.dims.keys)
            dimensionKeys.formUnion(after[index]!.dims.keys)
        }
        var dimDeltas: [DimensionDelta] = []
        for dimension in dimensionKeys.sorted() {
            let beforeValues = indices.compactMap { before[$0]!.dims[dimension] }
            let afterValues = indices.compactMap { after[$0]!.dims[dimension] }
            guard !beforeValues.isEmpty, !afterValues.isEmpty else { continue }
            dimDeltas.append(DimensionDelta(
                dimension: dimension,
                before: beforeValues.reduce(0, +) / Double(beforeValues.count),
                after: afterValues.reduce(0, +) / Double(afterValues.count)))
        }

        // ---- Top-N 与重合度 ----
        let topBefore = Array(indices.sorted { beforeRank[$0]! < beforeRank[$1]! }
            .prefix(topN))
        let topAfter = Array(indices.sorted { afterRank[$0]! < afterRank[$1]! }
            .prefix(topN))
        let topOverlap = Set(topBefore).intersection(Set(topAfter)).count

        // ---- 变化最大 ----
        let movers = indices.sorted { lhs, rhs in
            if deltas[lhs]! != deltas[rhs]! { return deltas[lhs]! > deltas[rhs]! }
            return lhs < rhs
        }

        comparison.comparable = indices.count
        comparison.changed = indices.filter { abs(deltas[$0]!) > 1e-9 }.count
        comparison.changedRatio = Double(comparison.changed) / Double(indices.count)
        // ⚠️ 按 indices 顺序累加，而不是遍历 Dictionary.values：
        // 浮点加法不满足结合律，Python 侧用的是插入顺序（即 indices 顺序）。
        comparison.meanDelta = indices.map { deltas[$0]! }.reduce(0, +)
            / Double(indices.count)
        comparison.meanAbsDelta = indices.map { abs(deltas[$0]!) }.reduce(0, +)
            / Double(indices.count)
        comparison.maxUp = movers.first.map(entry)
        comparison.maxDown = movers.last.map(entry)
        comparison.entries = indices.sorted { afterRank[$0]! < afterRank[$1]! }.map(entry)
        comparison.topBefore = topBefore.map(entry)
        comparison.topAfter = topAfter.map(entry)
        comparison.topOverlap = topOverlap
        comparison.spearman = spearman(indices.map { Double(beforeRank[$0]!) },
                                       indices.map { Double(afterRank[$0]!) })
        comparison.moversUp = indices.sorted { lhs, rhs in
            if rankDeltas[lhs]! != rankDeltas[rhs]! { return rankDeltas[lhs]! > rankDeltas[rhs]! }
            if deltas[lhs]! != deltas[rhs]! { return deltas[lhs]! > deltas[rhs]! }
            return lhs < rhs
        }.prefix(5).map(entry)
        comparison.moversDown = indices.sorted { lhs, rhs in
            if rankDeltas[lhs]! != rankDeltas[rhs]! { return rankDeltas[lhs]! < rankDeltas[rhs]! }
            if deltas[lhs]! != deltas[rhs]! { return deltas[lhs]! > deltas[rhs]! }
            return lhs < rhs
        }.prefix(5).map(entry)
        comparison.dimDeltas = dimDeltas
        return comparison
    }
}

// MARK: - 权重格式化

/// 与 Python `_fmt_weights` 一致：按键排序，值为 3 位小数。
public func formatWeights(_ weights: [String: Double]) -> String {
    weights
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\(String(format: "%.3f", $0.value))" }
        .joined(separator: " ")
}

// MARK: - 文本报告

extension History {

    /// 渲染前后对比报告，格式与 Python `render_report` 逐字符对齐。
    public static func renderReport(stats: ReevaluationStats,
                                    comparison: Comparison,
                                    evaluator: PaperEvaluator,
                                    topN: Int = 10) -> String {
        var lines: [String] = []
        let separator = String(repeating: "=", count: 72)

        lines.append(separator)
        lines.append("历史回溯 · 增量评价 · 前后对比报告")
        lines.append(separator)
        lines.append("生成日期            : \(PyCompat.isoDateString(Date()))")
        lines.append("历史记录总数        : \(stats.total)")
        lines.append("本次重评            : \(stats.reevaluated)")
        lines.append("沿用历史评分        : \(stats.skipped)")
        lines.append("原本就无评分        : \(stats.missingBefore)")

        if !stats.reasons.isEmpty {
            let detail = stats.reasons
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.label)×\($0.value)" }
                .joined(separator: "、")
            lines.append("重评原因分布        : \(detail)")
        }

        lines.append("")
        lines.append("---- 评分口径 ----")
        if stats.oldWeightSets.isEmpty {
            lines.append("历史权重            : （历史记录未保存权重）")
        } else {
            for weights in stats.oldWeightSets {
                lines.append("历史权重            : \(weights)")
            }
        }
        lines.append("当前权重            : \(formatWeights(evaluator.heuristic.weights))")
        lines.append("配置指纹            : \(evaluator.configKey)")

        lines.append("")
        lines.append("---- 可对比集合 ----")
        lines.append("前后均有评分        : \(comparison.comparable)")
        if comparison.comparable > 0 {
            lines.append("分数发生变化        : \(comparison.changed) "
                + "(\(String(format: "%.1f", comparison.changedRatio * 100))%)")
            lines.append("平均变化 / 平均绝对变化: "
                + "\(String(format: "%+.2f", comparison.meanDelta)) / "
                + "\(String(format: "%.2f", comparison.meanAbsDelta))")
        }

        if comparison.comparable > 0,
           let maxUp = comparison.maxUp, let maxDown = comparison.maxDown {
            lines.append("")
            lines.append("---- 分数变化最大 ----")
            for (label, item) in [("上升最多", maxUp), ("下降最多", maxDown)] {
                lines.append("\(label)            : "
                    + "\(String(format: "%+.2f", item.scoreDelta)) "
                    + "(\(String(format: "%.1f", item.beforeScore)) -> "
                    + "\(String(format: "%.1f", item.afterScore))) "
                    + "\(truncate(item.title, 52))")
            }
        }

        if comparison.comparable > 0 {
            lines.append("")
            lines.append("---- 排序稳定性 ----")
            lines.append("Spearman 相关系数   : \(String(format: "%.4f", comparison.spearman))")
            lines.append("Top-\(padRight(String(comparison.topN), 3))重合数        : "
                + "\(comparison.topOverlap)/\(comparison.topN)")

            lines.append("")
            lines.append("---- 名次变动 Top-5（升 / 降）----")
            for (label, items) in [("上升", comparison.moversUp), ("下降", comparison.moversDown)] {
                lines.append("  [\(label)]")
                for item in items {
                    lines.append("    \(String(format: "%+3d", item.rankDelta)) 位 "
                        + "(\(padLeft(String(item.beforeRank), 3)) -> "
                        + "\(padLeft(String(item.afterRank), 3))) "
                        + "score \(String(format: "%5.1f", item.beforeScore)) -> "
                        + "\(String(format: "%5.1f", item.afterScore)) | "
                        + "\(truncate(item.title, 46))")
                }
            }

            lines.append("")
            lines.append("---- 维度平均分变化 ----")
            for delta in comparison.dimDeltas {
                lines.append("  \(padRight(DimensionLabels.label(delta.dimension), 6)) "
                    + "\(String(format: "%.3f", delta.before)) -> "
                    + "\(String(format: "%.3f", delta.after))  "
                    + "(\(String(format: "%+.3f", delta.delta)))")
            }
        }

        lines.append("")
        lines.append("---- 新口径 Top-\(topN) ----")
        for (position, item) in comparison.topAfter.enumerated() {
            lines.append("  #\(String(format: "%02d", position + 1)) "
                + "\(String(format: "%5.1f", item.afterScore)) | "
                + "\(truncate(item.title, 60))")
        }
        lines.append(separator)

        return lines.joined(separator: "\n")
    }

    /// 一站式入口：回溯 + 增量重评 + 对比 + 报告。
    public static func run(_ papers: inout [Paper],
                           evaluator: PaperEvaluator,
                           force: Bool = false,
                           topN: Int = 10,
                           today: Date? = nil,
                           institutions: ((Paper) -> [String])? = nil) -> HistoryRunResult {
        let result = reevaluateHistory(&papers, evaluator: evaluator,
                                       force: force, today: today,
                                       institutions: institutions)
        let comparison = compareBeforeAfter(papers, before: result.before,
                                            after: result.after, topN: topN)
        let report = renderReport(stats: result.stats, comparison: comparison,
                                  evaluator: evaluator, topN: topN)
        return HistoryRunResult(stats: result.stats, comparison: comparison,
                                report: report)
    }

    // MARK: 私有格式化工具

    /// 按**码点**数截断，对齐 Python 的 `s[:n]`。
    static func truncate(_ s: String, _ count: Int) -> String {
        s.count > count ? String(s.prefix(count)) : s
    }

    /// 右填充到指定宽度（对齐 Python `:<n`）。
    static func padRight(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    /// 左填充到指定宽度（对齐 Python `:>n`）。
    static func padLeft(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }
}
