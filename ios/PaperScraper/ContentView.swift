//
//  ContentView.swift
//  PaperScraper
//
//  主列表：按综合分排序的论文，支持搜索与手动刷新。
//

import PaperScraperCore
import SwiftUI

struct ContentView: View {

    @Environment(AppModel.self) private var model

    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showHistory = false

    // 批量翻译标题
    @State private var batchProgress: String?
    @State private var batchMessage: String?
    @State private var batchError: String?

    /// 一次批量翻译的篇数。
    private static let batchLimit = 20
    /// 并发上限：够快，又不会把端侧模型或云端接口打爆。
    private static let batchConcurrency = 3

    private var visible: [(score: Double, paper: Paper)] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return model.ranked }
        return model.ranked.filter {
            $0.paper.title.lowercased().contains(needle)
                || $0.paper.authors.lowercased().contains(needle)
                || $0.paper.abstract.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.needsReevaluation { reevaluationHint }
                if hasTranslationActivity { translationBanner }

                if visible.isEmpty {
                    emptyState
                } else {
                    Section {
                        ForEach(Array(visible.enumerated()), id: \.element.paper.id) { index, item in
                            NavigationLink(value: item.paper) {
                                PaperRow(rank: index + 1,
                                         score: item.score,
                                         paper: item.paper,
                                         translatedTitle: model.translation(
                                            for: item.paper.url)?.title,
                                         keyFigure: keyFigure(for: item.paper),
                                         isLoadingFigure: isLoadingFigure(for: item.paper),
                                         institutions: model.institutions(for: item.paper),
                                         displayedDimensionKeys: model.settings
                                            .displayedDimensionKeys,
                                         onFigureFailure: model.markFigureBroken)
                            }
                            // 滚动到哪就抓哪：靠首屏固定预取无法覆盖几十上百行
                            .task { model.requestFigure(for: item.paper) }
                        }
                    } header: {
                        HStack {
                            Text("共 \(model.papers.count) 篇 · 当前显示 \(visible.count) 篇")
                            if model.isPrefetchingKeyFigures {
                                Spacer()
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.mini)
                                    Text("正在补全缩略图…")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await model.refresh() }
            .navigationTitle("论文雷达")
            .searchable(text: $searchText, prompt: "搜索标题 / 作者 / 摘要")
            .safeAreaInset(edge: .top, spacing: 0) { StatusBar() }
            .navigationDestination(for: Paper.self) { PaperDetailView(paper: $0) }
            .toolbar { toolbar }
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView() }
            }
            .sheet(isPresented: $showHistory) {
                NavigationStack { HistoryView() }
            }
        }
        .task {
            // ⚠️ 这里刻意**不**请求通知授权：系统授权弹窗会挂起 await，
            // 把首屏抓取一起挡住（实测过这个 bug）。授权改在用户打开通知开关时申请。
            await model.loadTranslations()
            await model.loadFigures()
            await model.loadKeyFigureOverrides()
            model.scheduleBackgroundRefresh()
            if model.papers.isEmpty {
                await model.refresh(notify: false)
            }
            // 首屏按排名预取前 N 篇；只入队不阻塞，剩下的交给滚动按需加载。
            model.prefetchKeyFigures(limit: model.settings.keyFigurePrefetchLimit)
        }
    }

    /// 该论文的缩略图是否正在抓取（用于在占位框里显示进度而不是空框）。
    private func isLoadingFigure(for paper: Paper) -> Bool {
        guard let id = FigureExtractor.arxivID(from: paper.url) else { return false }
        return model.loadingFigures.contains(id)
    }

    /// 列表行要显示的核心图。
    private func keyFigure(for paper: Paper) -> PaperFigure? {
        guard let id = FigureExtractor.arxivID(from: paper.url) else { return nil }
        return model.keyFigure(for: id)
    }

    // MARK: 片段

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showHistory = true } label: {
                Label("回溯对比", systemImage: "chart.line.uptrend.xyaxis")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: {
                Label("设置", systemImage: "gearshape")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    startBatchTranslation()
                } label: {
                    Label("翻译排名前 \(Self.batchLimit) 篇标题",
                          systemImage: "character.book.closed")
                }
                .disabled(model.papers.isEmpty || batchProgress != nil)

                Divider()

                Button {
                    model.prefetchKeyFigures(limit: model.settings.keyFigurePrefetchLimit)
                } label: {
                    Label("预取前 \(model.settings.keyFigurePrefetchLimit) 篇核心图",
                          systemImage: "photo.stack")
                }
                .disabled(model.papers.isEmpty
                          || model.isPrefetchingKeyFigures
                          || model.settings.keyFigurePrefetchLimit == 0)

                Divider()

                Button(role: .destructive) {
                    model.clearTranslations()
                    batchMessage = nil
                    batchError = nil
                } label: {
                    Label("清除译文缓存（\(model.translationCount) 篇）", systemImage: "trash")
                }
                .disabled(model.translationCount == 0)
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if model.phase.isBusy {
                ProgressView()
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var reevaluationHint: some View {
        Section {
            Button {
                Task { await model.reevaluate() }
            } label: {
                Label("评分口径已变更，点此按新口径增量重评", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.footnote)
            }
        }
    }

    private var hasTranslationActivity: Bool {
        batchProgress != nil || batchMessage != nil || batchError != nil
    }

    private var translationBanner: some View {
        Section {
            HStack(spacing: 10) {
                if batchProgress != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: batchError == nil
                          ? "character.book.closed" : "exclamationmark.triangle.fill")
                        .foregroundStyle(batchError == nil ? .green : .orange)
                }
                Text(batchProgress ?? batchError ?? batchMessage ?? "")
                    .font(.footnote)
                    .lineLimit(3)
                Spacer(minLength: 0)
                if batchProgress == nil {
                    Button("知道了") {
                        batchMessage = nil
                        batchError = nil
                    }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 批量翻译标题

    private func startBatchTranslation() {
        let pending = model.pendingTitleTranslations(limit: Self.batchLimit)
        guard !pending.isEmpty else {
            batchError = nil
            batchMessage = "排名前 \(Self.batchLimit) 篇都已有译文。"
            return
        }
        guard batchProgress == nil else { return }
        Task { await runBatchTranslation(pending) }
    }

    @MainActor
    private func runBatchTranslation(_ papers: [Paper]) async {
        batchError = nil
        batchMessage = nil

        var done = 0
        var failed = 0
        batchProgress = "正在翻译标题 0/\(papers.count)…"

        // 手动控制并发：维持 3 个在跑的任务，完成一个补一个
        await withTaskGroup(of: Bool.self) { group in
            var next = 0
            let concurrency = min(Self.batchConcurrency, papers.count)

            while next < concurrency {
                let paper = papers[next]
                group.addTask { @MainActor in
                    do {
                        try await model.translateTitleOnly(paper)
                        return true
                    } catch {
                        return false
                    }
                }
                next += 1
            }

            while let success = await group.next() {
                done += 1
                if !success { failed += 1 }
                batchProgress = "正在翻译标题 \(done)/\(papers.count)…"

                if next < papers.count {
                    let paper = papers[next]
                    group.addTask { @MainActor in
                        do {
                            try await model.translateTitleOnly(paper)
                            return true
                        } catch {
                            return false
                        }
                    }
                    next += 1
                }
            }
        }

        batchProgress = nil
        if failed == 0 {
            batchMessage = "已翻译 \(done) 篇标题，详情页可继续翻译摘要。"
        } else if failed == done {
            batchError = "\(failed) 篇全部失败，请检查「设置 → 中文翻译」里的引擎配置。"
        } else {
            batchMessage = "已翻译 \(done - failed) 篇，\(failed) 篇失败。"
        }
    }

    private var emptyState: some View {
        Section {
            ContentUnavailableView {
                Label(searchText.isEmpty ? "还没有论文记录" : "没有匹配结果",
                      systemImage: searchText.isEmpty ? "tray" : "magnifyingglass")
            } description: {
                Text(searchText.isEmpty
                     ? "下拉或点击右上角刷新，从 arXiv 抓取关键词「\(model.settings.query)」的最新论文。"
                     : "换个关键词试试。")
            }
        }
        .listRowBackground(Color.clear)
    }
}

// MARK: - 状态条

private struct StatusBar: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        if let message = model.phase.message {
            HStack(spacing: 10) {
                if model.phase.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.phase.isFailure
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.phase.isFailure ? .orange : .green)
                }
                Text(message)
                    .font(.footnote)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if !model.phase.isBusy {
                    Button("知道了") { model.clearStatus() }
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - 行

private struct PaperRow: View {

    let rank: Int
    let score: Double
    let paper: Paper
    /// 已缓存的中文标题；没有则为 nil（批量翻译只翻标题，摘要走详情页）。
    var translatedTitle: String?
    /// 已缓存的核心图；没有则为 nil —— 占位仍然渲染，避免行高跳动。
    var keyFigure: PaperFigure?
    /// 该论文的缩略图是否正在抓取。
    var isLoadingFigure: Bool = false
    /// 作者机构；尚未抓到时为空数组。
    var institutions: [String] = []
    /// 要展示的评分维度（键名，顺序即展示顺序）。
    var displayedDimensionKeys: [String] = DimensionLabels.allKeys
    /// 缩略图加载失败时上报（用于换下一张当核心图）。
    var onFigureFailure: (String) -> Void = { _ in }

    private var hasTranslation: Bool {
        !(translatedTitle ?? "").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                scoreColumn

                VStack(alignment: .leading, spacing: 4) {
                    titleBlock
                    authorsLine
                    if !institutions.isEmpty { institutionsLine }
                    dateText
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ListFigureThumbnail(figure: keyFigure, isLoading: isLoadingFigure,
                                    onFailure: onFigureFailure)
            }

            chipsRow
                // 左边留出评分列宽，让 chip 与标题左对齐；
                // 右端则一直伸到行尾 —— 那正好是缩略图**下方**的区域。
                // 之前 chip 被关在正文列里（约 180pt），右侧这块就一直是空的。
                .padding(.leading, Self.scoreColumnWidth + Self.columnSpacing)
        }
        // 行内要装标题、作者、机构、日期、芯片五层信息，上下留白刻意压得较紧：
        // 层次靠字号与颜色区分，不靠留白。
        .padding(.vertical, 6)
    }

    /// 左侧评分列宽。与 `ScoreBadge` 保持一致，避免两处各自硬编码后错位。
    static let scoreColumnWidth: CGFloat = 52
    static let columnSpacing: CGFloat = 10

    private var scoreColumn: some View {
        VStack(spacing: 3) {
            ScoreBadge(score: score)
            Text("#\(rank)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(width: Self.scoreColumnWidth)
    }

    // MARK: 各行

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hasTranslation ? translatedTitle! : paper.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if hasTranslation {
                // 保留英文原标题，便于核对与检索
                Text(paper.title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private var authorsLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "person.2")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(paper.authors)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 作者机构。没抓到时整行不渲染（而不是显示"未知"占位）。
    ///
    /// 最多显示两家，其余折叠成 "+N"：`Meta · UC Davis · Virginia Tech` 这种
    /// 一行放不下，而挤成省略号反而看不出任何信息。
    private var institutionsLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "building.columns")
                .font(.caption2)
                .foregroundStyle(Color.accentColor.opacity(0.85))
            Text(institutionSummary)
                .font(.caption)
                .foregroundStyle(Color.accentColor.opacity(0.9))
                .lineLimit(1)
        }
    }

    private var institutionSummary: String {
        let shown = institutions.prefix(2).joined(separator: " · ")
        let rest = institutions.count - min(2, institutions.count)
        return rest > 0 ? "\(shown) +\(rest)" : shown
    }

    /// 评分维度 chip 行。
    ///
    /// 用 `FlowLayout`（流式换行）而不是固定数量或 `ViewThatFits`：
    /// chip 数量是用户可配置的（最多 7 个），固定数量会在右侧留一片空白，
    /// 而 `ViewThatFits` 会直接降级到只显示两个。
    /// 流式布局按**实测宽度**逐行铺满，塞不下才换行。
    private var chipsRow: some View {
        FlowLayout(spacing: 4, lineSpacing: 2) {
            ForEach(dimensionChips, id: \.0) { key, value in
                chip(key: key, value: value)
            }
        }
    }

    private func chip(key: String, value: Double) -> some View {
        Text("\(DisplayFormat.dimensionLabel(key)) \(DisplayFormat.dimensionCompact(value))")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .fixedSize()
    }

    private var dateText: some View {
        Text(paper.submissionTime)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .fixedSize()
    }

    /// 要展示的评分维度。
    ///
    /// - 只保留**设置里勾选的**维度；
    /// - 再过滤掉这篇论文评分里不存在的（`venue` / `institution` 是有条件参与的，
    ///   没有数据的论文本来就没有这两项）；
    /// - 顺序跟随设置里的顺序，而不是按分数排序 —— 位置稳定才方便横向对比不同论文。
    private var dimensionChips: [(String, Double)] {
        guard let dims = paper.evaluation?.dimensionScores else { return [] }
        return displayedDimensionKeys.compactMap { key in
            guard let value = dims[key] else { return nil }
            return (key, value)
        }
    }
}

private struct ScoreBadge: View {
    let score: Double

    var body: some View {
        Text(score < 0 ? "—" : DisplayFormat.score(score))
            .font(.callout.monospacedDigit().weight(.semibold))
            .frame(width: PaperRow.scoreColumnWidth, height: 32)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch score {
        case ..<0: .secondary
        case ..<60: .orange
        case ..<75: .blue
        default: .green
        }
    }
}
