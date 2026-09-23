//
//  Figures.swift
//  PaperScraper
//
//  图表功能在 App 侧的两块拼图：**图表元数据缓存** 与 **全屏查看器**。
//
//  为什么只缓存元数据、不缓存图片本身
//  ----------------------------------
//  图片动辄几百 KB、一篇论文十几张，自己存会把沙箱撑得很大。
//  改成交给 `URLCache`（在 AppDelegate 里把容量调大），
//  由系统负责淘汰策略，代码量和风险都小得多。
//

import PaperScraperCore
import SwiftUI

// MARK: - 图表元数据缓存

/// 落盘到沙箱 `Documents/figures.json`，以 arXiv ID 为键。
actor FigureCache {

    private let fileURL: URL
    private var entries: [String: PaperFigureSet] = [:]
    private var didLoad = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func all() -> [String: PaperFigureSet] {
        loadIfNeeded()
        return entries
    }

    func store(_ set: PaperFigureSet) {
        loadIfNeeded()
        entries[set.arxivID] = set
        persist()
    }

    func removeAll() {
        entries = [:]
        didLoad = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([String: PaperFigureSet].self, from: data)) ?? [:]
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }

        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path)
    }
}

// MARK: - 核心图人工改选

/// 用户手动改选的核心图（arxivID -> 图片地址）。
///
/// 启发式选出的核心图可解释、也有实测支撑，但"哪张图最重要"终究有主观成分，
/// 因此必须给出人工改选的出口 —— 不认同就自己挑。
actor KeyFigureOverrideStore {

    private let fileURL: URL
    private var entries: [String: String] = [:]
    private var didLoad = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func all() -> [String: String] {
        loadIfNeeded()
        return entries
    }

    func set(_ imageURL: String?, for arxivID: String) {
        loadIfNeeded()
        if let imageURL {
            entries[arxivID] = imageURL
        } else {
            entries.removeValue(forKey: arxivID)
        }
        persist()
    }

    func removeAll() {
        entries = [:]
        didLoad = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path)
    }
}

// MARK: - 全屏查看器

/// 看图查看器。
///
/// 为什么不能只做"缩放到适应屏幕"
/// ------------------------------
/// 论文插图的长宽比对手机极不友好：双栏论文里的跨栏图经常是 4:1 甚至更扁，
/// 整张缩进屏幕后，坐标轴与标注文字完全无法辨认。
///
/// 因此提供两种模式，并在打开时按长宽比自动选择：
///
///   * **整图**：整张缩进屏幕。用于看清整体结构，细节靠双指放大。
///   * **分段**：以「高度填满视口」为缩放基准，于是横向会超出屏幕，
///     再按视口宽度**分页**左右翻看 —— 相当于把一张宽图切成几段可读的窗口。
///     这正是宽图在手机上唯一能看清文字的读法。
///
/// 对于比视口更高的图（纵向长图），分段退化为「宽度填满 + 上下滚动」，
/// 这本来就是手机上最自然的滚动方向。
struct FigureViewer: View {

    let figure: PaperFigure

    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case whole
        case segmented

        var id: String { rawValue }
        var displayName: String { self == .whole ? "整图" : "分段" }
    }

    /// 超过这个长宽比就默认进"分段"模式。
    private static let wideThreshold = 2.2

    @State private var mode: Mode = .whole

    /// 实际要显示的图片地址。
    ///
    /// 矢量图（SVG）要先栅格化成 PNG 才能被 `Image` 使用，而分段模式必须要拿到
    /// 可裁切的位图（WebView 没法配合位移裁切）。所以这里先解析出可用地址，
    /// 之后的整图 / 分段两种模式共用同一套渲染代码。
    @State private var displayURL: URL?
    @State private var isPreparing = false

    // 整图模式的缩放与平移
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    // 分段模式的当前页
    @State private var page = 0
    @State private var pageCount = 1

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    content(size: geometry.size)
                }
                captionBar
            }
            .background(Color(.systemBackground))
            .navigationTitle(figure.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("查看方式", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let url = URL(string: figure.imageURL) {
                        ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { resetZoom() }
                    } label: {
                        Label("还原", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(mode != .whole || (scale == 1 && offset == .zero))
                }
            }
        }
        .onAppear {
            // 宽图直接进分段模式，省得用户自己发现
            if let aspect = figure.aspectRatio, aspect >= Self.wideThreshold {
                mode = .segmented
            }
        }
        .task(id: figure.imageURL) { await prepareDisplayURL() }
    }

    /// 解析出可直接渲染的地址：位图用原地址，矢量图先栅格化到本地。
    private func prepareDisplayURL() async {
        guard figure.isVector else {
            displayURL = URL(string: figure.imageURL)
            return
        }
        // 已经栅格化过就直接用，避免每次打开都闪一下"正在渲染"
        if let cached = VectorRasterizer.shared.cachedRaster(for: figure.imageURL) {
            displayURL = cached
            return
        }
        isPreparing = true
        defer { isPreparing = false }
        displayURL = await VectorRasterizer.shared.raster(
            for: figure.imageURL,
            aspectRatio: figure.aspectRatio ?? 1.6)
    }

    // MARK: 内容

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if displayURL == nil {
            waitingView
        } else {
            switch mode {
            case .whole:
                wholeView
            case .segmented:
                segmentedView(size: size)
            }
        }
    }

    @ViewBuilder
    private var waitingView: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if isPreparing {
                VectorPendingPlaceholder()
            } else {
                VectorFailedPlaceholder(figure: figure)
            }
        }
    }

    /// 位图与栅格化后的矢量图共用。
    private func resolvedImage<Content: View>(
        @ViewBuilder content: @escaping (Image) -> Content
    ) -> some View {
        AsyncImage(url: displayURL) { phase in
            switch phase {
            case .success(let image): content(image)
            case .failure: VectorFailedPlaceholder(figure: figure)
            case .empty: ProgressView()
            @unknown default: EmptyView()
            }
        }
    }

    private var wholeView: some View {
        ZStack {
            Color(.secondarySystemBackground)

            resolvedImage { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnification)
                    .gesture(drag)
                    .onTapGesture(count: 2) { toggleZoom() }
            }
        }
    }

    @ViewBuilder
    private func segmentedView(size: CGSize) -> some View {
        let aspect = figure.aspectRatio ?? 1.6
        let viewportAspect = size.width / max(size.height, 1)

        if aspect >= viewportAspect {
            // 比视口宽：高度铺满 → 横向分页，每页是可读宽度的一段
            let displayHeight = size.height
            let displayWidth = displayHeight * aspect
            let count = max(1, Int((displayWidth / size.width).rounded(.up)))

            ZStack(alignment: .bottom) {
                resolvedImage { image in
                    TabView(selection: $page) {
                        ForEach(0..<count, id: \.self) { index in
                            slice(of: image, index: index,
                                  displayWidth: displayWidth,
                                  displayHeight: displayHeight,
                                  viewport: size)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
                .onAppear { pageCount = count }
                .onChange(of: count) { _, newValue in pageCount = newValue }

                segmentIndicator(count: count)
            }
        } else {
            // 比视口高：宽度铺满 → 纵向滚动（手机上最自然的方向）
            ScrollView(.vertical) {
                resolvedImage { image in
                    image
                        .resizable()
                        .frame(width: size.width, height: size.width / aspect)
                }
            }
            .onAppear { pageCount = 1 }
        }
    }

    /// 一页 = 大图上的一个窗口：整图左移 index 个视口宽，再裁掉超出部分。
    private func slice(of image: Image, index: Int,
                       displayWidth: CGFloat, displayHeight: CGFloat,
                       viewport: CGSize) -> some View {
        Color.clear
            .frame(width: viewport.width, height: viewport.height)
            .overlay(alignment: .topLeading) {
                image
                    .resizable()
                    .frame(width: displayWidth, height: displayHeight)
                    .offset(x: -CGFloat(index) * viewport.width)
            }
            .clipped()
    }

    private func segmentIndicator(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(page + 1)/\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)

            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.white : Color.white.opacity(0.4))
                        .frame(width: 6, height: 6)
                }
            }

            Text("左右滑动")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(.bottom, 12)
        .opacity(count > 1 ? 1 : 0)
    }

    // MARK: 说明区

    private var captionBar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(figure.caption.isEmpty ? "（这张图没有图注）" : figure.caption)
                    .font(.footnote)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    // 不展示"原图 W × H"：LaTeXML 给的 width/height 是排版尺寸，
                    // 真实像素宽是它的 3–10 倍，写出来会误导。长宽比才是可靠的，
                    // 也正是决定"要不要分段看"的那个量。
                    if let aspect = figure.aspectRatio {
                        Text(String(format: "长宽比 %.1f : 1", aspect))
                    }
                    if figure.referenceCount > 0 {
                        Text("正文引用 \(figure.referenceCount) 次")
                    }
                    if figure.isAppendix {
                        Text("位于附录")
                    }
                    if mode == .segmented, pageCount > 1 {
                        Text("已分 \(pageCount) 段")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxHeight: 170)
    }

    // MARK: 手势

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(committedScale * value, 1), 8)
            }
            .onEnded { _ in
                committedScale = scale
                if scale <= 1 { resetZoom() }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height)
            }
            .onEnded { _ in committedOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if scale > 1 { resetZoom() } else { scale = 2.5 }
        }
    }

    private func resetZoom() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
    }
}

// MARK: - 缩略图

/// 详情页里的单张图预览。宽高比来自 HTML 里的 width/height，
/// 这样图片加载完成前就能占好位，避免横向列表跳动。
struct FigureThumbnail: View {

    let figure: PaperFigure
    let onTap: () -> Void

    private static let width: CGFloat = 220

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: URL(string: figure.imageURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder(systemImage: "photo", text: "加载失败")
                    case .empty:
                        ProgressView().controlSize(.small)
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: Self.width, height: height)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                }

                Text(figure.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: Self.width, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var height: CGFloat {
        // 极端长宽比会把列表撑得很难看，限制在合理区间
        guard let ratio = figure.aspectRatio, ratio > 0 else { return 150 }
        return min(max(Self.width / ratio, 90), 240)
    }

    private func placeholder(systemImage: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.title3)
            Text(text).font(.caption2)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - 列表缩略图

/// 列表行里的核心图小图。
///
/// 尺寸**固定**，不按原图长宽比算：列表是扫读场景，
/// 行高随图片跳动会比图片被裁掉一点更让人难受。
/// 宽图用 `fill` 居中裁切，露出中间最有信息量的部分。
struct ListFigureThumbnail: View {

    /// nil 表示核心图还没预取到，此时显示占位并保留空间。
    let figure: PaperFigure?
    /// 是否正在抓取。区分"正在加载"与"这篇就是没图"，
    /// 否则用户看到的两种情况完全一样（都是空框）。
    var isLoading: Bool = false
    /// 图片加载失败时回调（带上失败的地址，用于换下一张当核心图）。
    var onFailure: ((String) -> Void)?

    static let width: CGFloat = 96
    static let height: CGFloat = 78

    var body: some View {
        Group {
            if let figure {
                // 矢量图要现栅格化，首屏可能会先看到占位 —— 这是刻意的：
                // 列表要滚动流畅，不能为了几张缩略图阻塞。
                FigureImage(figure: figure, contentMode: .fill) {
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        placeholder(systemImage: figure.isVector
                                    ? "photo.badge.arrow.down" : "photo")
                    }
                } failure: {
                    placeholder(systemImage: "photo.badge.exclamationmark")
                        .onAppear { onFailure?(figure.imageURL) }
                }
            } else if isLoading {
                ProgressView().controlSize(.mini)
            } else {
                placeholder(systemImage: "photo.on.rectangle")
            }
        }
        .frame(width: Self.width, height: Self.height)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        }
    }

    private func placeholder(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - 核心图卡片

/// 详情页顶部的核心图展示位。
///
/// 高度不按"原图比例"直接算：论文里的跨栏总览图常有 4:1 以上的长宽比，
/// 按比例算出来只有几十点高，会完全失去"这是论文主图"的分量。
/// 所以按屏幕宽度估算后再夹到 `130...320` 之间 ——
/// 宁可让极宽的图上下留白，也要保证核心图的视觉重量。
struct KeyFigureCard: View {

    let figure: PaperFigure
    /// 图片加载失败时回调（带上失败的地址）。
    var onFailure: ((String) -> Void)?

    /// 正文区域宽度约为屏宽减去两侧 20 点内边距。
    private var estimatedWidth: CGFloat {
        UIScreen.main.bounds.width - 40
    }

    private var height: CGFloat {
        let width = max(estimatedWidth, 200)
        let ratio = figure.aspectRatio ?? 1.5
        return min(max(width / ratio, 130), 320)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            FigureImage(figure: figure, contentMode: .fit) {
                VectorPendingPlaceholder()
            } failure: {
                VectorFailedPlaceholder(figure: figure)
                    .onAppear { onFailure?(figure.imageURL) }
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(Color(.secondarySystemBackground))

            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        }
    }
}
