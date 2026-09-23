//
//  AppModel.swift
//  PaperScraper
//
//  应用状态与用例编排：对应 `main.py` 的两种工作模式。
//
//    * `refresh()`     <-> `python main.py`（抓取 -> 去重 -> 评分 -> 落盘）
//    * `reevaluate()`  <-> `python main.py --revaluate`（离线增量重评 + 对比报告）
//

import Foundation
import Observation
import PaperScraperCore

@MainActor
@Observable
final class AppModel {

    /// 全局唯一实例。
    ///
    /// 后台任务处理器在 AppDelegate 启动回调里注册，那个时点拿不到 SwiftUI 的
    /// `@State`，因此需要一个可全局访问的实例。
    static let shared = AppModel()

    enum Phase: Equatable {
        case idle
        case working(String)
        case finished(String)
        case failed(String)

        var message: String? {
            switch self {
            case .idle: nil
            case .working(let text), .finished(let text), .failed(let text): text
            }
        }

        var isBusy: Bool {
            if case .working = self { true } else { false }
        }

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }
    }

    // MARK: 状态

    private(set) var papers: [Paper] = []
    private(set) var ranked: [(score: Double, paper: Paper)] = []
    private(set) var phase: Phase = .idle
    private(set) var reportText = ""
    private(set) var lastRunAt: Date?
    private(set) var lastNewCount = 0
    private(set) var hasAPIKey = false
    private(set) var hasTranslationKey = false

    /// 权重 / 增强开关变更后，历史评分已不是当前口径，需要提示用户重评。
    private(set) var needsReevaluation = false

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            let scoringChanged = settings.weightPresetName != oldValue.weightPresetName
                || settings.useExternal != oldValue.useExternal
                || settings.useLLM != oldValue.useLLM
            if scoringChanged, !papers.isEmpty { needsReevaluation = true }
        }
    }

    // MARK: 依赖

    /// 前台抓取：等待可以久一点，允许重试。
    private let client = ArxivClient()

    /// 后台刷新专用客户端。
    ///
    /// 后台预算只有约 30 秒，而默认配置的最坏耗时是
    /// 4 次尝试 × 30 秒超时 + 1+2+4 秒退避 ≈ 127 秒 —— 在后台必然被系统掐断。
    /// 这里压缩到「2 次尝试 × 15 秒超时 + 2 秒退避 ≈ 32 秒」，
    /// 并保留 3 秒请求间隔以继续遵守 arXiv 的 API 规范。
    private let backgroundClient = ArxivClient(timeout: 15, minInterval: 3.0, maxRetries: 1)

    private let enricher = ExternalEnricher()
    private let metadataURL = PaperStore.defaultURL()

    /// 译文缓存（沙箱 Documents/translations.json）。
    private let translationCache = TranslationCache(
        fileURL: PaperStore.documentsDirectory()
            .appendingPathComponent("translations.json"))

    /// 图表元数据缓存（沙箱 Documents/figures.json）。图片本体交给 URLCache。
    private let figureCache = FigureCache(
        fileURL: PaperStore.documentsDirectory()
            .appendingPathComponent("figures.json"))
    private let figureExtractor = FigureExtractor()

    /// 核心图的人工改选记录（沙箱 Documents/keyfigures.json）。
    private let keyFigureStore = KeyFigureOverrideStore(
        fileURL: PaperStore.documentsDirectory()
            .appendingPathComponent("keyfigures.json"))

    private var apiKey = ""
    /// 翻译专用的 Key，与打分用的分开：两者完全可能是不同服务商。
    private var translationKey = ""

    /// 当前口径的评估器（权重 + 增强开关 + LLM 是否可用）。
    var evaluator: PaperEvaluator {
        let preset = WeightPreset.all.first { $0.name == settings.weightPresetName }
        return PaperEvaluator(weights: preset?.weights,
                              useExternal: settings.useExternal,
                              llmEnabled: settings.useLLM && hasAPIKey)
    }

    var scoredCount: Int {
        papers.filter { $0.evaluation?.finalScore != nil }.count
    }

    var unscoredCount: Int { papers.count - scoredCount }

    var storageBytes: Int64 {
        PaperStore.directorySize(at: PaperStore.documentsDirectory())
    }

    // MARK: 生命周期

    init() {
        settings = AppSettings.load()
        apiKey = KeychainStore.read(KeychainStore.llmAPIKeyName) ?? ""
        hasAPIKey = !apiKey.isEmpty
        translationKey = KeychainStore.read(KeychainStore.translationAPIKeyName) ?? ""
        hasTranslationKey = !translationKey.isEmpty
        loadFromDisk()
    }

    func loadFromDisk() {
        do {
            papers = try PaperStore.load(from: metadataURL)
            recomputeRanking()
        } catch {
            phase = .failed("读取本地元数据失败：\(error.localizedDescription)")
        }
    }

    /// 按已存储的评分排序；同分保持原始顺序（与 Python 的稳定排序一致）。
    private func recomputeRanking() {
        let indexed = papers.enumerated().map {
            (index: $0.offset, score: $0.element.evaluation?.finalScore ?? -1, paper: $0.element)
        }
        ranked = indexed
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
            .map { (score: $0.score, paper: $0.paper) }
    }

    // MARK: 常规抓取

    @discardableResult
    func refresh(notify: Bool = true) async -> Int {
        await refresh(using: client, notify: notify)
    }

    /// 抓取 + 去重 + 评分 + 落盘的实际实现。
    ///
    /// - Parameter client: 前台用 `client`；后台用 `backgroundClient`（超时更短）。
    @discardableResult
    private func refresh(using client: ArxivClient, notify: Bool) async -> Int {
        guard !phase.isBusy else { return 0 }

        phase = .working("正在从 arXiv 抓取…")
        do {
            let fetched = try await client.fetchPapers(ArxivQuery(
                query: settings.query,
                maxResults: settings.maxResults,
                sortBySubmittedDate: settings.sortBySubmittedDate))

            let known = Set(papers.map(\.url))
            var incoming = fetched.filter { !known.contains($0.url) }
            lastNewCount = incoming.count
            lastRunAt = Date()

            guard !incoming.isEmpty else {
                phase = .finished("本次抓取 \(fetched.count) 篇，没有新论文")
                return 0
            }

            phase = .working("正在评分 \(incoming.count) 篇新论文…")
            incoming = await score(incoming)

            papers.append(contentsOf: incoming)
            try PaperStore.save(papers, to: metadataURL)
            recomputeRanking()
            needsReevaluation = false

            phase = .finished("新增 \(incoming.count) 篇（本次抓取 \(fetched.count) 篇）")
            if notify, settings.notifyOnNewPapers {
                await LocalNotifier.notifyNewPapers(
                    count: incoming.count, topTitle: ranked.first?.paper.title)
            }
            return incoming.count
        } catch {
            phase = .failed(error.localizedDescription)
            return 0
        }
    }

    /// 对一批论文评分（可选叠加外部增强与 LLM 分）。
    private func score(_ input: [Paper]) async -> [Paper] {
        let evaluator = self.evaluator
        let key = apiKey
        let useExternal = settings.useExternal
        let useLLM = evaluator.llmEnabled
        let llm = LLMEvaluator(baseURL: settings.llmBaseURL, model: settings.llmModel)

        var output: [Paper] = []
        output.reserveCapacity(input.count)

        for var paper in input {
            // 与 Python 一致：先启发式，再混外部，最后混 LLM
            var evaluation = evaluator.evaluate(paper)

            let signals = useExternal ? await enricher.enrich(paper) : nil
            let llmResult = (useLLM && !key.isEmpty)
                ? await llm.evaluate(paper, apiKey: key) : nil

            evaluation = evaluator.applying(
                evaluation,
                externalScore: signals?.externalScore,
                externalRaw: signals?.jsonValue() ?? .null,
                llmScore: llmResult?.llmScore,
                llmRaw: llmResult?.jsonValue() ?? .null)

            paper.evaluation = evaluation
            output.append(paper)
        }
        return output
    }

    // MARK: 历史回溯

    func reevaluate(force: Bool = false) async {
        guard !phase.isBusy else { return }
        guard !papers.isEmpty else {
            phase = .finished("本地还没有论文记录")
            return
        }

        phase = .working("正在回溯重评…")

        var working = papers
        // 必须把机构一起传进去：它是"有条件参与"的维度，
        // 不传的话重评会把已经并入的机构维度丢掉，那些论文的分数会退回旧口径。
        let sets = figureSets
        let result = History.run(&working, evaluator: evaluator, force: force, topN: 10,
                                 institutions: { paper in
            guard let id = FigureExtractor.arxivID(from: paper.url) else { return [] }
            return sets[id]?.institutions ?? []
        })

        papers = working
        reportText = result.report
        recomputeRanking()
        needsReevaluation = false

        if result.stats.reevaluated > 0 {
            // 与 Python 一样：落盘前先备份
            _ = try? PaperStore.backup(of: metadataURL)
            do {
                try PaperStore.save(papers, to: metadataURL)
            } catch {
                phase = .failed("写入失败：\(error.localizedDescription)")
                return
            }
        }

        phase = .finished(result.stats.reevaluated == 0
            ? "没有任何记录需要重算（沿用 \(result.stats.skipped) 条）"
            : "重评 \(result.stats.reevaluated) 条，沿用 \(result.stats.skipped) 条")
    }

    // MARK: 后台刷新

    func scheduleBackgroundRefresh() {
        BackgroundRefresh.schedule(enabled: settings.backgroundRefreshEnabled)
    }

    /// 由 `BGAppRefreshTask` 调用。注意先排下一次，再执行抓取。
    func performBackgroundRefresh() async {
        scheduleBackgroundRefresh()
        await refresh(using: backgroundClient, notify: true)
    }

    // MARK: LLM Key

    func updateAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = trimmed
        hasAPIKey = !trimmed.isEmpty

        if trimmed.isEmpty {
            KeychainStore.delete(KeychainStore.llmAPIKeyName)
        } else {
            KeychainStore.save(trimmed, for: KeychainStore.llmAPIKeyName)
        }
        if !papers.isEmpty { needsReevaluation = true }
    }

    // MARK: 翻译

    /// 已缓存的译文，键为论文 url。
    private(set) var translations: [String: PaperTranslation] = [:]

    var translationCount: Int { translations.count }

    func translation(for url: String) -> PaperTranslation? { translations[url] }

    func loadTranslations() async {
        translations = await translationCache.all()
    }

    func storeTranslation(_ translation: PaperTranslation, for url: String) {
        translations[url] = translation
        Task { await translationCache.store(translation, for: url) }
    }

    func clearTranslations() {
        translations = [:]
        Task { await translationCache.removeAll() }
    }

    /// 需要翻译标题、且尚无译文的论文，按当前排名从高到低取前 `limit` 篇。
    ///
    /// 评分高的论文更可能被打开，先翻这些性价比最高。
    func pendingTitleTranslations(limit: Int) -> [Paper] {
        var result: [Paper] = []
        for entry in ranked where translations[entry.paper.url] == nil {
            result.append(entry.paper)
            if result.count >= limit { break }
        }
        return result
    }

    // ---- 引擎 ----

    enum TranslationSetup {
        case ready(any TranslationEngine)
        case unavailable(String)
    }

    /// 自定义术语表（内置术语在 `TranslationGlossary` 里，用户项优先）。
    var glossary: TranslationGlossary {
        TranslationGlossary(
            userEntries: TranslationGlossary.parseUserEntries(
                settings.translationGlossaryText))
    }

    /// 按当前设置构造引擎；不可用时给出**具体原因**，而不是静默失败。
    func translationSetup() -> TranslationSetup {
        let kind = TranslationEngineKind(rawValue: settings.translationEngine)
            ?? .appleIntelligence

        switch kind {
        case .appleIntelligence:
            guard #available(iOS 26.0, *) else {
                return .unavailable("端侧大模型需要 iOS 26 及以上")
            }
            if let reason = AppleIntelligenceEngine.unavailableReason {
                return .unavailable(reason)
            }
            return .ready(AppleIntelligenceEngine(glossary: glossary))

        case .openAICompatible:
            guard !translationKey.isEmpty else {
                return .unavailable("还没有填写翻译用的 API Key")
            }
            guard !settings.translationBaseURL.isEmpty,
                  !settings.translationModel.isEmpty else {
                return .unavailable("Base URL 或模型名未填写")
            }
            return .ready(OpenAICompatibleEngine(
                baseURL: settings.translationBaseURL,
                model: settings.translationModel,
                apiKey: translationKey,
                glossary: glossary))
        }
    }

    /// 取引擎，不可用时抛错（错误信息可直接展示给用户）。
    func currentTranslationEngine() throws -> any TranslationEngine {
        switch translationSetup() {
        case .ready(let engine): return engine
        case .unavailable(let reason): throw TranslationEngineError.unavailable(reason)
        }
    }

    // ---- 翻译动作 ----

    /// 翻译一篇论文的标题与摘要。
    ///
    /// 先译标题，再把标题译文作为上下文传给摘要翻译 —— 这是保持术语一致的
    /// 一个廉价且有效的手段。
    @discardableResult
    func translatePaper(_ paper: Paper) async throws -> PaperTranslation {
        let engine = try currentTranslationEngine()

        let translatedTitle = try await engine.translate(
            paper.title, kind: .title, context: nil)

        var translatedAbstract = ""
        if !paper.abstract.isEmpty, paper.abstract != "N/A" {
            translatedAbstract = try await engine.translate(
                paper.abstract, kind: .abstract, context: translatedTitle)
        }

        let translation = PaperTranslation(
            title: Self.cleanup(translatedTitle),
            abstract: Self.cleanup(translatedAbstract),
            targetLanguage: TranslationTarget.identifier,
            translatedAt: Date(),
            engine: engine.displayName)

        storeTranslation(translation, for: paper.url)
        return translation
    }

    /// 只翻译标题（批量场景）。摘要保持原样，留待详情页按需翻译。
    @discardableResult
    func translateTitleOnly(_ paper: Paper) async throws -> PaperTranslation {
        let engine = try currentTranslationEngine()
        let translatedTitle = try await engine.translate(
            paper.title, kind: .title, context: nil)

        let translation = PaperTranslation(
            title: Self.cleanup(translatedTitle),
            abstract: translations[paper.url]?.abstract ?? "",
            targetLanguage: TranslationTarget.identifier,
            translatedAt: Date(),
            engine: engine.displayName)

        storeTranslation(translation, for: paper.url)
        return translation
    }

    /// 清掉模型偶尔带出来的"译文："前缀与包裹引号。
    private static func cleanup(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["译文：", "译文:", "翻译：", "翻译:"] where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.count >= 2, result.hasPrefix("\""), result.hasSuffix("\"") {
            result = String(result.dropFirst().dropLast())
        }
        return result
    }

    // MARK: 翻译 Key

    func updateTranslationKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        translationKey = trimmed
        hasTranslationKey = !trimmed.isEmpty

        if trimmed.isEmpty {
            KeychainStore.delete(KeychainStore.translationAPIKeyName)
        } else {
            KeychainStore.save(trimmed, for: KeychainStore.translationAPIKeyName)
        }
    }

    // MARK: 图表

    /// 图表集合，以 arXiv ID 为键。
    private(set) var figureSets: [String: PaperFigureSet] = [:]

    var figureCacheCount: Int { figureSets.count }

    func loadFigures() async {
        figureSets = await figureCache.all()
    }

    func figureSet(for arxivID: String) -> PaperFigureSet? { figureSets[arxivID] }

    /// 取（或抓）某篇论文的图表。
    ///
    /// 注意缓存策略：**只把有图的结果落盘**。
    /// “没有 HTML 版”这类否定结果留在内存里供本次会话展示提示，
    /// 但不持久化 —— 否则论文后来有了 HTML 也永远不会重试。
    func loadFigureSet(arxivID: String, force: Bool = false) async -> PaperFigureSet {
        if !force, let cached = figureSets[arxivID] { return cached }

        let fetched = await figureExtractor.fetch(arxivID: arxivID)

        // 抓取失败时不要覆盖已有的成功结果
        if fetched.figures.isEmpty, let cached = figureSets[arxivID],
           !cached.figures.isEmpty {
            return cached
        }

        figureSets[arxivID] = fetched
        if !fetched.figures.isEmpty {
            await figureCache.store(fetched)
        }
        // 机构到了就把这几篇补评一遍（队列空了才真正重算，见 applyPendingInstitutionScores）
        if !fetched.institutions.isEmpty {
            queueInstitutionRescore(arxivID: arxivID)
        }
        return fetched
    }

    // MARK: 按需加载（列表滚动触发）

    /// 正在排队或抓取中的 arXiv ID，供列表显示"加载中"。
    ///
    /// 为什么不能只靠开头预取固定篇数
    /// ------------------------------
    /// 列表有几十到上百篇，而每张缩略图都要一次约 300KB 的 HTML 抓取。
    /// 一次性全抓既慢又浪费；只抓前 N 篇则会让绝大多数行永远是空框 ——
    /// 实测真机上 100 篇只预取 10 篇，用户看到的正是"图片没加载"。
    ///
    /// 所以改成：开头仍按排名预取前 N 篇，之后**滚动到哪就抓哪**。
    /// 抓取仍由下面的串行队列统一节流，快速滑动不会打出一串并发请求。
    private(set) var loadingFigures: Set<String> = []
    private var figureQueue: [String] = []
    private var figureWorker: Task<Void, Never>?

    /// 请求某篇论文的图表（已缓存或已在队列里则直接返回）。
    func requestFigure(for paper: Paper) {
        guard let id = FigureExtractor.arxivID(from: paper.url) else { return }
        requestFigure(arxivID: id)
    }

    func requestFigure(arxivID: String) {
        guard figureSets[arxivID] == nil,
              !loadingFigures.contains(arxivID) else { return }

        loadingFigures.insert(arxivID)
        figureQueue.append(arxivID)

        guard figureWorker == nil else { return }
        figureWorker = Task { [weak self] in
            await self?.drainFigureQueue()
        }
    }

    /// 串行消费队列。每个请求之间的间隔由 `FigureExtractor` 内部的节流保证。
    private func drainFigureQueue() async {
        while !figureQueue.isEmpty {
            if Task.isCancelled { break }
            let id = figureQueue.removeFirst()
            // 队列里可能累积了用户快速滑过的行；已经不需要了就跳过
            defer { loadingFigures.remove(id) }
            if figureSets[id] != nil { continue }
            _ = await loadFigureSet(arxivID: id)
        }
        figureWorker = nil
        // 整批抓完后统一补评一次，避免边抓边重排边写盘
        applyPendingInstitutionScores()
    }

    func clearFigures() {
        figureSets = [:]
        Task { await figureCache.removeAll() }
        // 图片本体在 URLCache 里，一起清掉
        URLCache.shared.removeAllCachedResponses()
        // SVG 是提前栅格化落盘的，不归 URLCache 管，必须单独清
        VectorRasterizer.shared.removeAll()
    }

    /// 已栅格化的矢量图张数（设置页展示用）。
    var vectorCacheCount: Int { VectorRasterizer.shared.cachedCount() }

    /// 该论文的作者机构（尚未抓到时为空数组）。
    func institutions(for paper: Paper) -> [String] {
        guard let id = FigureExtractor.arxivID(from: paper.url) else { return [] }
        return figureSets[id]?.institutions ?? []
    }

    // MARK: 机构补评

    /// 拿到机构信息、但评分里还没有"机构"维度的论文。
    ///
    /// 为什么需要补评这一步
    /// ------------------
    /// 评分发生在抓列表的时候，那时还没有机构信息（机构要额外抓一次 HTML）。
    /// 所以抓到机构之后要把这几篇重新评一遍，机构维度才会反映到分数上。
    ///
    /// 批量收集、队列空了再统一重算，是为了避免预取过程中反复重排 + 反复写盘。
    private var pendingInstitutionRescore: Set<String> = []

    private func queueInstitutionRescore(arxivID: String) {
        guard let index = papers.firstIndex(where: {
            FigureExtractor.arxivID(from: $0.url) == arxivID
        }) else { return }
        guard papers[index].evaluation?.dimensionScores["institution"] == nil else {
            // 已经有机构维度了（比如上次运行算过），不必重算
            return
        }
        pendingInstitutionRescore.insert(arxivID)
    }

    /// 把机构维度补进相应论文的分数，并落盘。
    ///
    /// 会保留原有的外部增强分与 LLM 分：它们被记在 `evaluation.external` /
    /// `evaluation.llm` 里（含换算后的标量分），这里读回来重新 `applying`，
    /// 否则重算会把用户开启的增强效果悄悄抹掉。
    func applyPendingInstitutionScores() {
        guard !pendingInstitutionRescore.isEmpty else { return }
        let ids = pendingInstitutionRescore
        pendingInstitutionRescore = []

        let evaluator = self.evaluator
        var changed = false

        for index in papers.indices {
            guard let id = FigureExtractor.arxivID(from: papers[index].url),
                  ids.contains(id),
                  let institutions = figureSets[id]?.institutions,
                  !institutions.isEmpty
            else { continue }

            let previous = papers[index].evaluation
            var evaluation = evaluator.evaluate(papers[index], institutions: institutions)
            evaluation.external = previous?.external ?? .null
            evaluation.llm = previous?.llm ?? .null
            evaluation = evaluator.applying(
                evaluation,
                externalScore: previous?.external?.scalarScore(forKey: "external_score"),
                externalRaw: previous?.external ?? .null,
                llmScore: previous?.llm?.scalarScore(forKey: "llm_score"),
                llmRaw: previous?.llm ?? .null)

            papers[index].evaluation = evaluation
            changed = true
        }

        guard changed else { return }
        recomputeRanking()
        _ = try? PaperStore.backup(of: metadataURL)
        try? PaperStore.save(papers, to: metadataURL)
    }

    // MARK: 核心图

    /// 用户手动改选的核心图（arxivID -> 图片地址）。
    private(set) var keyFigureOverrides: [String: String] = [:]

    func loadKeyFigureOverrides() async {
        keyFigureOverrides = await keyFigureStore.all()
    }

    /// 该论文当前生效的核心图：
    /// 人工改选优先，否则用启发式选出的那张（跳过已知下载不到的坏图）。
    func keyFigure(for arxivID: String) -> PaperFigure? {
        guard let set = figureSets[arxivID] else { return nil }
        if let chosen = keyFigureOverrides[arxivID],
           let figure = set.figures.first(where: { $0.imageURL == chosen }) {
            return figure
        }
        return KeyFigureSelector.select(from: set.figures, excluding: brokenFigureURLs)
    }

    /// 本次运行里已经确认下载不到的图片地址。
    ///
    /// 不落盘：一次网络抖动就会把一张好图永久拉黑，得不偿失。
    /// 重启后重试一次完全可接受。
    private(set) var brokenFigureURLs: Set<String> = []

    /// 图片加载失败时调用（缩略图与详情页都会报）。
    ///
    /// 有些论文的 HTML 里图片路径指向不存在的文件（实测 `2404.07677`），
    /// 这时应该换下一张当门面，而不是留一个永远的空框 —— 那正是
    /// 用户看到"图片没加载"的直接原因。
    func markFigureBroken(_ imageURL: String) {
        guard !brokenFigureURLs.contains(imageURL) else { return }
        brokenFigureURLs.insert(imageURL)
    }

    /// 这张图是不是用户手动改选的（用来在 UI 上区分"自动/手动"）。
    func isManuallyChosen(_ figure: PaperFigure, arxivID: String) -> Bool {
        keyFigureOverrides[arxivID] == figure.imageURL
    }

    /// 手动改选核心图；传 `nil` 表示恢复自动选择。
    func setKeyFigure(_ figure: PaperFigure?, arxivID: String) {
        if let figure {
            keyFigureOverrides[arxivID] = figure.imageURL
        } else {
            keyFigureOverrides.removeValue(forKey: arxivID)
        }
        Task { await keyFigureStore.set(figure?.imageURL, for: arxivID) }
    }

    /// 是否还有图在排队抓取（列表头部据此显示进度）。
    var isPrefetchingKeyFigures: Bool { !loadingFigures.isEmpty }

    /// 首屏按排名预取前 `limit` 篇的核心图。
    ///
    /// 只负责**入队**，然后立即返回：真正的抓取由 `drainFigureQueue` 在后台串行完成。
    /// 这样即便用户马上滚走或切页，已排队的抓取也不会被取消，
    /// 而后续滚动触发的按需请求会自然接在同一个队列后面。
    ///
    /// - Parameter limit: 首屏预取篇数，0 表示不预取（仍可按需加载）。
    /// - Returns: 本次实际入队的篇数。
    @discardableResult
    func prefetchKeyFigures(limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        // 首屏这段是"用户还没提出需求"的主动抓取，所以遵守只走 Wi-Fi 的策略。
        // 滚动触发的按需加载不设这道闸 —— 那是用户明确在浏览的行。
        guard NetworkPolicy.shared.allowsBulkPrefetch(settings.wifiOnlyPrefetch) else {
            #if DEBUG
            // 把"已判定为计费网络"和"还没判定出来"分开记：
            // 两者在界面上都是"没有缩略图"，但原因完全不同。
            print("[Prefetch] 跳过首屏预取：isMetered=\(NetworkPolicy.shared.isMetered) "
                  + "isResolved=\(NetworkPolicy.shared.isResolved)")
            #endif
            return 0
        }

        var queued = 0
        for entry in ranked {
            if queued >= limit { break }
            guard let id = FigureExtractor.arxivID(from: entry.paper.url) else { continue }
            guard figureSets[id] == nil, !loadingFigures.contains(id) else { continue }
            loadingFigures.insert(id)
            figureQueue.append(id)
            queued += 1
        }

        if queued > 0, figureWorker == nil {
            figureWorker = Task { [weak self] in
                await self?.drainFigureQueue()
            }
        }
        return queued
    }

    // MARK: 数据管理

    func deleteAllRecords() {
        papers = []
        ranked = []
        reportText = ""
        needsReevaluation = false
        _ = try? FileManager.default.removeItem(at: metadataURL)
        _ = try? FileManager.default.removeItem(at: PaperStore.backupURL(for: metadataURL))
        phase = .finished("已清空本地记录")
    }

    func clearStatus() {
        if case .finished = phase { phase = .idle }
    }
}
