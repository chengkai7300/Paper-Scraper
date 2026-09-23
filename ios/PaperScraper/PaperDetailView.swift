//
//  PaperDetailView.swift
//  PaperScraper
//
//  论文详情：评分拆解、摘要、原文链接。
//
//  关于 PDF：与 Python 侧 `--download` 不同，iOS 版**不落盘 PDF**。
//  原因是 150 篇 PDF 约 174 MB，会同时抬高沙箱占用与 iCloud 备份体积，
//  且移动端阅读体验本就依赖 Quick Look / 浏览器。这里改为按需打开外链。
//

import PaperScraperCore
import SwiftUI

struct PaperDetailView: View {

    @Environment(AppModel.self) private var model

    let paper: Paper

    @State private var isTranslating = false
    @State private var translationError: String?
    @State private var showingOriginal = false

    // 图表
    @State private var figureSet: PaperFigureSet?
    @State private var isLoadingFigures = false
    @State private var selectedFigure: PaperFigure?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                keyFigureSection
                if let evaluation = paper.evaluation {
                    scoreSection(evaluation)
                    dimensionSection(evaluation)
                } else {
                    unscoredNotice
                }
                abstractSection
                figuresSection
                linkSection
            }
            .padding(20)
        }
        .navigationTitle("论文详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { translationControl }
        }
        .task { await loadFiguresIfNeeded() }
        .sheet(item: $selectedFigure) { figure in
            FigureViewer(figure: figure)
        }
    }

    // MARK: 翻译状态

    private var translation: PaperTranslation? { model.translation(for: paper.url) }

    /// 有译文且用户没有切回原文时才显示中文。
    private var isShowingTranslation: Bool {
        !showingOriginal && translation != nil
    }

    /// 标题与摘要**分别**回退：批量翻译只翻标题，此时摘要应继续显示英文。
    private var displayTitle: String {
        guard isShowingTranslation, let translated = translation?.title,
              !translated.isEmpty else { return paper.title }
        return translated
    }

    private var displayAbstract: String {
        guard isShowingTranslation, let translated = translation?.abstract,
              !translated.isEmpty else { return paper.abstract }
        return translated
    }

    // MARK: 片段

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayTitle)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            if isShowingTranslation, translation?.title.isEmpty == false {
                Text(paper.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Label(paper.authors, systemImage: "person.2")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // 机构要等抓过一次 HTML 才有，所以这里可能出现在页面加载之后
            if !institutions.isEmpty {
                Label(institutions.joined(separator: " · "),
                      systemImage: "building.columns")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
            }

            Label(paper.submissionTime, systemImage: "calendar")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var translationControl: some View {
        if isTranslating {
            ProgressView().controlSize(.small)
        } else if translation != nil {
            Button {
                showingOriginal.toggle()
            } label: {
                Label(showingOriginal ? "显示译文" : "显示原文",
                      systemImage: showingOriginal ? "character.book.closed" : "textformat")
            }
        } else {
            Button {
                startTranslation()
            } label: {
                Label("翻译为中文", systemImage: "character.book.closed")
            }
        }
    }

    // MARK: 翻译动作

    private func startTranslation() {
        Task { await performTranslation() }
    }

    @MainActor
    private func performTranslation() async {
        isTranslating = true
        translationError = nil
        defer { isTranslating = false }

        do {
            try await model.translatePaper(paper)
            showingOriginal = false
        } catch {
            translationError = error.localizedDescription
        }
    }

    private func scoreSection(_ evaluation: Evaluation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(DisplayFormat.score(evaluation.finalScore ?? 0))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()

            VStack(alignment: .leading, spacing: 2) {
                Text("综合分 / 100").font(.footnote).foregroundStyle(.secondary)
                if let base = evaluation.baseScore, base != evaluation.finalScore {
                    Text("启发式部分 \(DisplayFormat.score(base))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text("评分日期 \(evaluation.evaluatedOn ?? "—")")
                    .font(.caption2).foregroundStyle(.tertiary)
                if let key = evaluation.configKey {
                    Text("配置指纹 \(key)")
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func dimensionSection(_ evaluation: Evaluation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("维度明细")
                .font(.headline)

            ForEach(orderedDimensions(evaluation), id: \.0) { key, score in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(DisplayFormat.dimensionLabel(key))
                            .font(.subheadline)
                        Spacer()
                        Text(DisplayFormat.dimension(score))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let weight = evaluation.weights[key] {
                            Text("×\(DisplayFormat.dimension(weight))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geometry.size.width * min(1, max(0, score)))
                        }
                    }
                    .frame(height: 6)
                }
            }

            if let external = evaluation.external, case .object = external {
                Divider()
                Text("已启用外部引用增强（Semantic Scholar / HuggingFace）")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var unscoredNotice: some View {
        Label("这篇论文还没有评分，可在设置里执行一次回溯重评。",
              systemImage: "exclamationmark.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var abstractSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("摘要").font(.headline)
            Text(displayAbstract)
                .font(.callout)
                .textSelection(.enabled)
            translationFooter
        }
    }

    @ViewBuilder
    private var translationFooter: some View {
        if let message = translationError {
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("可在「设置 → 中文翻译」里更换翻译引擎或补全 API Key。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let translation {
            HStack(spacing: 6) {
                Image(systemName: "character.book.closed")
                Text("机器翻译 · \(translation.engine ?? translation.targetLanguage)")
                Spacer()
                Button("重新翻译") { startTranslation() }
                    .font(.caption2)
                    .disabled(isTranslating)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        } else {
            // 还没有译文时，提前把"引擎不可用"的原因说清楚，而不是等用户点了才报错
            switch model.translationSetup() {
            case .ready(let engine):
                Text("翻译引擎：\(engine.displayName)。专业术语可在设置里的术语表中自定义。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .unavailable(let reason):
                Label("\(reason)（可在「设置 → 中文翻译」中调整）",
                      systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 图表

    private var arxivID: String? { FigureExtractor.arxivID(from: paper.url) }

    /// 作者机构（来自同一次 arXiv HTML 抓取）。
    private var institutions: [String] {
        if let arxivID, let set = model.figureSet(for: arxivID) {
            return set.institutions
        }
        return figureSet?.institutions ?? []
    }

    /// 当前生效的核心图：人工改选优先，否则用自动选出的那张。
    private var keyFigure: PaperFigure? {
        if let arxivID, let chosen = model.keyFigure(for: arxivID) { return chosen }
        return figureSet?.keyFigure
    }

    /// 核心图之外的全部图，仍然在页面底部完整展示。
    private var otherFigures: [PaperFigure] {
        guard let figureSet else { return [] }
        let key = keyFigure?.imageURL
        return figureSet.figures.filter { $0.imageURL != key }
    }

    private var isManuallyChosenKey: Bool {
        guard let arxivID, let key = keyFigure else { return false }
        return model.isManuallyChosen(key, arxivID: arxivID)
    }

    /// 页面顶部的核心图。
    ///
    /// 位置刻意放在标题之后、评分之前 —— 读论文先看图是本能，
    /// 而评分是"要不要细看"的判断依据，两者都不该被推到折叠线以下。
    @ViewBuilder
    private var keyFigureSection: some View {
        if let figure = keyFigure {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label("核心图", systemImage: "star.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)

                    if isManuallyChosenKey {
                        Text("手动选择")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    Text(figure.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    selectedFigure = figure
                } label: {
                    KeyFigureCard(figure: figure) { model.markFigureBroken($0) }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if isManuallyChosenKey, let arxivID {
                        Button {
                            model.setKeyFigure(nil, arxivID: arxivID)
                        } label: {
                            Label("恢复自动选择", systemImage: "wand.and.stars")
                        }
                    }
                    if let url = URL(string: figure.imageURL) {
                        ShareLink(item: url) { Label("分享图片", systemImage: "square.and.arrow.up") }
                    }
                }

                if !figure.caption.isEmpty {
                    Text(figure.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                Text("点按查看大图（宽图可分段左右翻阅）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else if isLoadingFigures {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在挑选核心图…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var figuresSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("全部图表").font(.headline)
                if let figureSet, !figureSet.figures.isEmpty {
                    Text("\(figureSet.figures.count) 张")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoadingFigures {
                    ProgressView().controlSize(.small)
                } else if figureSet?.figures.isEmpty == false {
                    Button {
                        Task { await loadFigures(force: true) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                }
            }

            if isLoadingFigures, figureSet == nil {
                Text("正在从 arXiv 的 HTML 版提取图表…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let figureSet {
                if figureSet.figures.isEmpty {
                    Label(figureSet.note ?? "这篇论文没有可展示的图表",
                          systemImage: "photo.on.rectangle.angled")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    if otherFigures.isEmpty {
                        Text("这张就是全文唯一的插图，已在页面顶部展示。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(otherFigures) { figure in
                                    FigureThumbnail(figure: figure) {
                                        selectedFigure = figure
                                    }
                                    .contextMenu {
                                        if let arxivID {
                                            Button {
                                                model.setKeyFigure(figure, arxivID: arxivID)
                                            } label: {
                                                Label("设为核心图", systemImage: "star")
                                            }
                                        }
                                        if let url = URL(string: figure.imageURL) {
                                            ShareLink(item: url) {
                                                Label("分享图片", systemImage: "square.and.arrow.up")
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        Text("长按任意图可设为核心图")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if let source = figureSet.sourceURL, let url = URL(string: source) {
                        Link("在 arXiv HTML 版中查看上下文", destination: url)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func loadFiguresIfNeeded() async {
        guard figureSet == nil else { return }
        await loadFigures(force: false)
    }

    private func loadFigures(force: Bool) async {
        guard let arxivID = FigureExtractor.arxivID(from: paper.url) else {
            figureSet = PaperFigureSet(arxivID: "", note: "无法从链接解析出 arXiv 编号")
            return
        }
        if !force, let cached = model.figureSet(for: arxivID) {
            figureSet = cached
            return
        }
        isLoadingFigures = true
        defer { isLoadingFigures = false }
        figureSet = await model.loadFigureSet(arxivID: arxivID, force: force)
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("原文").font(.headline)

            if let url = URL(string: paper.url) {
                Link(destination: url) {
                    Label("打开 arXiv 摘要页", systemImage: "safari")
                }
            }
            if let pdfURL = paper.pdfURL {
                Link(destination: pdfURL) {
                    Label("打开 PDF", systemImage: "doc.richtext")
                }
            }

            ShareLink(item: shareText) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
        .font(.callout)
    }

    // MARK: 工具

    /// 按固定维度顺序展开，仅保留有值的维度。
    private func orderedDimensions(_ evaluation: Evaluation) -> [(String, Double)] {
        var result: [(String, Double)] = []
        for key in Evaluation.orderedDimensionKeys {
            if let value = evaluation.dimensionScores[key] {
                result.append((key, value))
            }
        }
        return result
    }

    private var shareText: String {
        var lines = [paper.title, paper.authors, paper.url]
        if let score = paper.evaluation?.finalScore {
            lines.insert("综合分 \(DisplayFormat.score(score))", at: 1)
        }
        return lines.joined(separator: "\n")
    }
}
