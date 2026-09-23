//
//  VectorFigure.swift
//  PaperScraper
//

import PaperScraperCore
import SwiftUI
import UIKit
import WebKit

// MARK: - 矢量图栅格化

/// 把 arXiv 的 SVG 图栅格化成 PNG，缓存到沙箱。
///
/// 为什么非做不可
/// --------------
/// LaTeXML 对位图输出 `<img>`，对**矢量图**输出
/// `<object type="image/svg+xml" data="….svg">`。抽样 6 篇论文共 46 张图，
/// 两者**各占一半**（img 23 / object 23）；`2402.12317` 更是 6 张里 5 张是 SVG。
/// 而 UIKit 完全解不了 SVG —— 不做这一步，App 就等于丢掉一半的图。
///
/// 为什么是"离屏截图"而不是"内嵌一个 WebView 显示"
/// --------------------------------------------
/// 查看器的"分段"模式要靠 `Image` + 位移裁切来实现（见 `FigureViewer`），
/// 换成 WebView 就得把分页逻辑重写一遍。所以统一策略是：
/// **先把 SVG 栅格化成普通的 PNG，之后全 App 都当位图处理，只有一条渲染路径。**
@MainActor
final class VectorRasterizer {

    static let shared = VectorRasterizer()

    private let directory: URL
    private var running: [String: Task<URL?, Never>] = [:]

    /// 目标高度。查看器的分段模式要把图铺满视口高度（iPhone 约 600pt ≈ 1800px @3x），
    /// 1400px 是个折中：再高对屏幕上的观感几乎没有提升，文件却明显变大。
    private let targetHeight: CGFloat = 1400
    /// 长边上限（**像素**）。
    /// WebKit 把内容渲染进一张纹理，iOS 上单边上限通常在 4096 像素附近；
    /// 超了不会报错，而是**整张渲染成空白**（实测 `any-precision.svg` 踩过）。
    /// 3200 留了足够裕量。
    private let maxLongSide: CGFloat = 3200

    private init() {
        directory = PaperStore.documentsDirectory().appendingPathComponent("vector")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    /// 已经栅格化好的本地文件地址；没有则返回 nil。
    func cachedRaster(for remoteURL: String) -> URL? {
        let file = fileURL(for: remoteURL)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        // 只把"存在且有内容"算作命中：写到一半被系统杀掉会留下 0 字节文件，
        // 若当成命中，这张图就会永远显示不出来（而且缓存还在，不会自愈）。
        guard size > 0 else { return nil }
        return file
    }

    /// 取栅格图，必要时现场生成。同一个地址的并发请求会合并成一次渲染。
    func raster(for remoteURL: String, aspectRatio: CGFloat) async -> URL? {
        if let cached = cachedRaster(for: remoteURL) { return cached }

        if let existing = running[remoteURL] {
            return await existing.value
        }

        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.render(remoteURL: remoteURL, aspectRatio: aspectRatio)
        }
        running[remoteURL] = task

        let result = await task.value
        running[remoteURL] = nil
        return result
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        running = [:]
    }

    func cachedCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? 0
    }

    // MARK: 渲染

    private func fileURL(for remoteURL: String) -> URL {
        // 用 SHA-1 而不是 hashValue：Swift 的 hashValue 每个进程都会换种子，
        // 同一个地址重启后文件名就变了，缓存等于没有。
        directory.appendingPathComponent(PyCompat.sha1Hex(remoteURL, prefix: 20) + ".png")
    }

    private func targetSize(aspectRatio: CGFloat) -> CGSize {
        // 长宽比可能缺失或离谱（0、负数、极大），先夹到可用区间
        let ratio = min(max(aspectRatio, 0.05), 40)
        var size = CGSize(width: targetHeight * ratio, height: targetHeight)
        if size.width > maxLongSide {
            size = CGSize(width: maxLongSide, height: maxLongSide / ratio)
        }
        size.height = max(size.height, 80)
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    private func render(remoteURL: String, aspectRatio: CGFloat) async -> URL? {
        guard let url = URL(string: remoteURL) else { return nil }

        // size 是目标**像素**尺寸。
        // WebView 的帧要用**点**，所以要按屏幕倍率除一次 ——
        // 直接用像素当点数会让纹理宽高变成三倍，超过 WebKit 的上限而渲染成空白。
        let pixels = targetSize(aspectRatio: aspectRatio)
        let scale = UIScreen.main.scale
        let size = CGSize(width: pixels.width / scale, height: pixels.height / scale)

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size),
                                configuration: configuration)
        webView.isUserInteractionEnabled = false
        webView.scrollView.isScrollEnabled = false

        // 离屏的 WKWebView 不会渲染，截图会得到空白，必须挂进可见窗口。
        //
        // ⚠️ 不能用 `alpha = 0.02` 这种"低透明度藏起来"的做法：
        // `takeSnapshot` 会把视图自身的 alpha 一起烘进结果，导出的 PNG 整体
        // 变成近乎白色的淡影（实测踩过这个坑，图确实渲出来了但完全看不清）。
        // 改成插到窗口**最底层**、alpha 保持 1 —— 上面的 App 界面是不透明的，
        // 用户看不到，而 WebKit 照常渲染。
        let host = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow
        webView.alpha = 1
        host?.insertSubview(webView, at: 0)
        defer { webView.removeFromSuperview() }

        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html,body{margin:0;padding:0;background:#ffffff;overflow:hidden}
          img{display:block;width:100%;height:auto}
        </style></head>
        <body><img id="figure" src="\(url.absoluteString)"></body></html>
        """

        do {
            try await load(html: html, in: webView, size: size)
            // `didFinish` 只代表文档加载完，图片可能还在解码，等它自然尺寸可用
            try await waitForImage(in: webView, timeout: 8)

            // 截图并确认**不是空白**。
            // `img.complete` 只说明解码完了，不等于已经合成绘制 ——
            // 复杂 SVG 会晚几帧才真正画出来，此时截到的是纯白图。
            // 不检查的话会把一张白图当成结果缓存起来，而且永远不会自愈。
            guard let snapshot = try await snapshotInked(of: webView) else {
                print("[VectorRasterizer] 截图始终为空白，放弃：\(remoteURL)")
                return nil
            }

            // 输出尺寸以屏幕倍率放大，重采样保证与目标像素尺寸完全一致。
            let target = targetSize(aspectRatio: aspectRatio)
            let image = resample(snapshot, to: target)

            guard let data = image.pngData(), !data.isEmpty else { return nil }
            let file = fileURL(for: remoteURL)
            try data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: file.path)
            return file
        } catch {
            // 栅格化失败不该是致命错误：调用方会退回占位图
            print("[VectorRasterizer] 栅格化失败 \(remoteURL)：\(error.localizedDescription)")
            return nil
        }
    }

    private func load(html: String, in webView: WKWebView, size: CGSize) async throws {
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        _ = try await withCheckedThrowingContinuation { continuation in
            waiter.attach(continuation)
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// 轮询 `naturalWidth`，确认 SVG 真的解码出来了。
    private func waitForImage(in webView: WKWebView, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let script = """
        (function(){var i=document.getElementById('figure');
         return i ? (i.complete && i.naturalWidth > 0) : false;})()
        """
        while Date() < deadline {
            let ready = (try? await webView.evaluateJavaScript(script)) as? Bool ?? false
            if ready { return }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        throw VectorRasterError.imageNotReady
    }

    private func snapshot(of webView: WKWebView) async throws -> UIImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        // 不设 `snapshotWidth`：它的单位语义在不同系统版本上不一致
        // （实测同一份代码出现过“按点算”和“按像素算”两种结果），
        // 输出尺寸统一交给后面的 `resample` 保证。
        return try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? VectorRasterError.snapshotFailed)
                }
            }
        }
    }

    /// 反复截图直到拿到“有内容”的一张；始终空白则返回 nil。
    private func snapshotInked(of webView: WKWebView, attempts: Int = 4) async throws -> UIImage? {
        var last: UIImage?
        for attempt in 0..<attempts {
            // 逐次加长等待：复杂 SVG 需要更多帧才画完
            let delay = 0.25 + Double(attempt) * 0.55
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            let shot = try await snapshot(of: webView)
            last = shot
            if !isBlank(shot) { return shot }
        }
        guard let last else { return nil }
        return isBlank(last) ? nil : last
    }

    /// 判断一张图是不是“基本纯白”。
    ///
    /// 按**原分辨率**抽样扫描（默认每 2 个像素取 1 个），不做降采样：
    /// 降采样会把细线条平均掉，稀疏的折线图会被误判成空白。
    private func isBlank(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return true }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return true }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let threshold: UInt8 = 246
        for y in stride(from: 0, to: height, by: 2) {
            var index = y * bytesPerRow
            for _ in stride(from: 0, to: width, by: 2) {
                if pixels[index] < threshold
                    || pixels[index + 1] < threshold
                    || pixels[index + 2] < threshold {
                    return false
                }
                index += 8
            }
        }
        return true
    }

    /// 重采样到指定像素尺寸，同时把透明底压成白底（论文插图都按白底看）。
    private func resample(_ image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rect = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(rect)
            image.draw(in: rect)
        }
    }
}

enum VectorRasterError: Error {
    case imageNotReady
    case snapshotFailed
    case navigationFailed(String)
}

/// 把 `WKNavigationDelegate` 的回调桥接成 `async`。
///
/// 单独一个小对象而不是让 `VectorRasterizer` 兼任：`WKNavigationDelegate` 要求
/// `NSObject` 子类，而 `VectorRasterizer` 是个纯 Swift 的 actor 风格单例。
@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {

    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        settle(.failure(VectorRasterError.navigationFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        settle(.failure(VectorRasterError.navigationFailed(error.localizedDescription)))
    }

    private func settle(_ result: Result<Void, Error>) {
        guard !settled, let continuation else { return }
        settled = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}

// MARK: - 统一的图片视图

/// 按需渲染的一张图：位图直接走 `AsyncImage`，矢量图先栅格化再当位图用。
///
/// 把两种来源收在一个视图里，是为了让详情页、列表、查看器共用同一条渲染路径 ——
/// 否则"核心图正好是 SVG"这种情形会在三处各写一遍分支。
struct FigureImage<Placeholder: View, Failure: View>: View {

    let figure: PaperFigure
    var contentMode: ContentMode = .fit
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure

    @State private var rasterURL: URL?

    var body: some View {
        Group {
            if figure.isVector {
                if let rasterURL {
                    AsyncImage(url: rasterURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: contentMode)
                        case .failure: failure()
                        case .empty: placeholder()
                        @unknown default: EmptyView()
                        }
                    }
                } else {
                    placeholder()
                        .task(id: figure.imageURL) { await rasterize() }
                }
            } else {
                AsyncImage(url: URL(string: figure.imageURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: contentMode)
                    case .failure: failure()
                    case .empty: placeholder()
                    @unknown default: EmptyView()
                    }
                }
            }
        }
    }

    private func rasterize() async {
        let aspect = figure.aspectRatio ?? 1.6
        rasterURL = await VectorRasterizer.shared.raster(for: figure.imageURL,
                                                         aspectRatio: aspect)
    }
}

// MARK: - 矢量图占位

/// 矢量图正在栅格化时显示。
///
/// 明确写出"正在渲染矢量图"而不是转个圈：首次看到一篇论文的图时会多等一两秒，
/// 用户需要知道这不是卡住了。
struct VectorPendingPlaceholder: View {

    var body: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("正在渲染矢量图…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 矢量图栅格化失败时的占位。
struct VectorFailedPlaceholder: View {

    let figure: PaperFigure

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.badge.exclamationmark").font(.title3)
            Text("矢量图渲染失败").font(.caption2)
            if let url = URL(string: figure.imageURL) {
                Link("用浏览器打开", destination: url).font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
