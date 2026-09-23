//
//  Support.swift
//  PaperScraper
//
//  App 层的基础设施：设置持久化、Keychain、后台刷新排期、本地通知、格式化。
//
//  iOS 特有三处与 Python CLI 的对应关系
//  ------------------------------------
//  * `os.environ` 里的开关        -> `AppSettings`（UserDefaults）
//  * `OPENAI_API_KEY` 环境变量    -> Keychain（不能进 UserDefaults，也不进代码库）
//  * 命令行 `--query/--max/...`   -> 设置页
//

import BackgroundTasks
import Foundation
import Network
import PaperScraperCore
import Security
import UserNotifications

// MARK: - 设置

struct AppSettings: Codable, Equatable {
    var query: String = "LLM"
    var maxResults: Int = 50
    var sortBySubmittedDate: Bool = false

    /// 权重档位（与 `WeightPreset.all` 中的 name 对应）。
    var weightPresetName: String = "default"
    var useExternal: Bool = false
    var useLLM: Bool = false

    var backgroundRefreshEnabled: Bool = true
    var notifyOnNewPapers: Bool = true

    /// 与 Python 的 `OPENAI_BASE_URL` / `OPENAI_MODEL` 默认值一致。
    var llmBaseURL: String = "https://api.openai.com/v1"
    var llmModel: String = "gpt-4o-mini"

    // MARK: 翻译
    /// `TranslationEngineKind` 的 rawValue。
    var translationEngine: String = "appleIntelligence"
    /// `TranslationProvider` 的 id。
    var translationProviderID: String = "deepseek"
    var translationBaseURL: String = "https://api.deepseek.com/v1"
    var translationModel: String = "deepseek-chat"
    /// 自定义术语表，每行一条 `英文 => 中文`。
    var translationGlossaryText: String = ""

    // MARK: 图表
    /// 列表页为核心图预取的篇数（0 = 关闭）。
    var keyFigurePrefetchLimit: Int = 10
    /// 只在 Wi-Fi 下做批量预取。
    var wifiOnlyPrefetch: Bool = true

    /// 列表行要显示哪些评分维度（键名与 `DimensionLabels` 一致）。
    var displayedDimensionKeys: [String] = AppSettings.defaultDisplayedDimensions

    /// 默认显示全部维度。
    ///
    /// 默认全开而不是只留核心几项：列表行的正文列本来就有一大片横向空白，
    /// 只显示两三个 chip 会浪费掉，而用户想看的是"这篇为什么排在这"。
    /// 嫌挤可以在设置里逐项关掉。
    static let defaultDisplayedDimensions = DimensionLabels.allKeys

    private static let storageKey = "AppSettings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: 向后兼容的解码
    //
    // ⚠️ 这一段是必须的，不是"优化"。
    // 合成的 Decodable 遇到**缺失的键就直接抛错**，于是 `load()` 会静默退回
    // 全新默认值 —— 也就是说每次新增一个设置项，老用户的所有设置（查询词、
    // 权重档位、翻译服务商、术语表……）都会被清空一次。
    // 这里用 `decodeIfPresent` + 默认值，让新增字段天然向后兼容。
    private enum CodingKeys: String, CodingKey {
        case query, maxResults, sortBySubmittedDate
        case weightPresetName, useExternal, useLLM
        case backgroundRefreshEnabled, notifyOnNewPapers
        case llmBaseURL, llmModel
        case translationEngine, translationProviderID
        case translationBaseURL, translationModel, translationGlossaryText
        case keyFigurePrefetchLimit, wifiOnlyPrefetch
        case displayedDimensionKeys
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            guard let decoded = try? container.decodeIfPresent(T.self, forKey: key) else {
                return fallback
            }
            return decoded ?? fallback
        }

        query = value(.query, defaults.query)
        maxResults = value(.maxResults, defaults.maxResults)
        sortBySubmittedDate = value(.sortBySubmittedDate, defaults.sortBySubmittedDate)
        weightPresetName = value(.weightPresetName, defaults.weightPresetName)
        useExternal = value(.useExternal, defaults.useExternal)
        useLLM = value(.useLLM, defaults.useLLM)
        backgroundRefreshEnabled = value(.backgroundRefreshEnabled,
                                        defaults.backgroundRefreshEnabled)
        notifyOnNewPapers = value(.notifyOnNewPapers, defaults.notifyOnNewPapers)
        llmBaseURL = value(.llmBaseURL, defaults.llmBaseURL)
        llmModel = value(.llmModel, defaults.llmModel)
        translationEngine = value(.translationEngine, defaults.translationEngine)
        translationProviderID = value(.translationProviderID,
                                     defaults.translationProviderID)
        translationBaseURL = value(.translationBaseURL, defaults.translationBaseURL)
        translationModel = value(.translationModel, defaults.translationModel)
        translationGlossaryText = value(.translationGlossaryText,
                                       defaults.translationGlossaryText)
        keyFigurePrefetchLimit = value(.keyFigurePrefetchLimit,
                                      defaults.keyFigurePrefetchLimit)
        wifiOnlyPrefetch = value(.wifiOnlyPrefetch, defaults.wifiOnlyPrefetch)
        displayedDimensionKeys = value(.displayedDimensionKeys,
                                       defaults.displayedDimensionKeys)
    }
}

// MARK: - Keychain

enum KeychainStore {

    static let llmAPIKeyName = "llm-api-key"
    /// 翻译单独用一份 Key：打分与翻译完全可能用不同的服务商。
    static let translationAPIKeyName = "translation-api-key"

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "PaperScraper"
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        delete(account)
        var query = baseQuery(account)
        query[kSecValueData as String] = Data(value.utf8)
        // 只在本机可用，且不参与 iCloud 钥匙串同步
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary) == errSecSuccess
    }
}

// MARK: - 后台刷新

/// `BGAppRefreshTask` 的注册与排期管理。
///
/// ⚠️ 必须清醒认识其能力边界：**系统决定何时执行，且不保证执行**。
/// 用户长期不打开 App 时，后台刷新可能完全不被调用。
/// 因此"每日自动抓取"这类承诺不能只依赖它 —— 见 README 的说明。
enum BackgroundRefresh {

    static let taskIdentifier = "com.chengkai.paperscraper.refresh"

    /// 注册后台任务处理器。
    ///
    /// ⚠️ **必须在 `application(_:didFinishLaunchingWithOptions:)` 里调用**。
    /// BGTaskScheduler 有一条硬性约束：
    /// `All launch handlers must be registered before application finishes launching`
    /// —— 违反它会直接抛 `NSInternalInconsistencyException` 崩溃（实测已复现）。
    /// 这也是本项目没有采用 SwiftUI `.backgroundTask` 修饰符的原因：它注册得太晚。
    static func registerHandler(_ handler: @escaping @Sendable () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier,
                                        using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }

            let work = Task { await handler() }
            // 系统收回时间片时立刻取消网络请求，避免被强杀
            refreshTask.expirationHandler = { work.cancel() }

            Task {
                await work.value
                refreshTask.setTaskCompleted(success: !work.isCancelled)
            }
        }
    }

    /// 下一次后台刷新的"最早可开始"延迟。
    ///
    /// 🔧 **真机调试时把它改成 60**，就能在几分钟内反复验证后台刷新；
    /// 上线前记得改回 6 小时（再短会明显增加耗电与被系统降频的概率）。
    static let minimumDelay: TimeInterval = 6 * 3600

    /// 排期下一次后台刷新。每次执行后都必须重新排期，否则不会再触发。
    static func schedule(enabled: Bool) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        guard enabled else { return }

        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        // earliestBeginDate 只是"最早可以开始"，不是"将在此时执行"
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumDelay)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // 模拟器不支持后台任务排期，这里会稳定失败；真机上才会生效
            print("[BackgroundRefresh] 排期失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 网络策略

/// 判断当前网络是否"按流量计费"。
///
/// 为什么不能"每次用的时候现测一次"
/// ------------------------------
/// 早期版本每次都新建一个 `NWPathMonitor`，再用信号量阻塞等首次回调
/// （最多 0.5 秒），超时一律当作计费网络。三个问题：
///
///   1. **阻塞主线程最多半秒**。调用方 `prefetchKeyFigures` 在 `@MainActor` 上，
///      等于把首屏卡住 —— 而这只是为了一次"要不要顺手多抓几张图"的判断。
///   2. **每次调用都新建监视器 + 新开队列**，比读一个缓存值贵得多。
///   3. **"拿不到结果"被当成"计费网络"**，会静默关掉预取，而且没有任何日志，
///      极难排查（表现为"图片不加载"，但看日志只能看到一个 `false`）。
///
/// 现在改成：App 启动时建**一个**监视器，回调在后台队列更新缓存值，
/// 读取时只取缓存（不加锁等待任何东西）。首次回调到达前用
/// `NWPathMonitor.currentPath` 的同步快照兜底。
///
/// `isResolved` 单独暴露出来，是为了让日志能区分
/// "已判定为计费网络"和"还没判定出来"—— 这两种情况在界面上表现一样，
/// 但原因完全不同。
final class NetworkPolicy: @unchecked Sendable {

    static let shared = NetworkPolicy()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    /// 判定为"计费 / 不可用"网络。未判定前保守地按 `true` 处理。
    private var metered = true
    /// 是否已经收到过至少一次路径回调。
    private var resolved = false

    private init() {
        // ⚠️ `currentPath` 在 `start()` 之前没有意义，所以先 start 再取快照。
        // 这个快照在首次回调到达前生效。
        monitor.start(queue: DispatchQueue(
            label: "com.chengkai.paperscraper.network-monitor",
            qos: .utility))

        apply(monitor.currentPath, resolved: false)

        monitor.pathUpdateHandler = { [weak self] path in
            self?.apply(path, resolved: true)
        }
    }

    private func apply(_ path: NWPath, resolved: Bool) {
        lock.lock()
        defer { lock.unlock() }
        metered = Self.isMetered(path)
        self.resolved = resolved
    }

    private static func isMetered(_ path: NWPath) -> Bool {
        // 没连上 / 路径不可用：也算"受限"，此时本来也抓不到东西
        guard path.status == .satisfied else { return true }
        return path.isExpensive
    }

    /// 是否处于计费或不可用的网络。
    var isMetered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return metered
    }

    /// 是否已经拿到过网络状态（false 表示还在用启动快照兜底）。
    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    /// 是否允许做"批量但不紧急"的抓取。
    ///
    /// 只用于**首屏预取**（用户还没提出需求，属于主动抓取）。
    /// 滚动触发的按需加载不走这里 —— 那是用户明确在看的内容。
    func allowsBulkPrefetch(_ wifiOnly: Bool) -> Bool {
        guard wifiOnly else { return true }
        return !isMetered
    }
}

// MARK: - 本地通知

enum LocalNotifier {

    private static let identifier = "new-papers"

    /// 申请通知授权。
    ///
    /// ⚠️ 只在用户**主动打开通知开关**时调用：系统弹窗会挂起 `await`，
    /// 如果出现在首屏启动路径上，会把网络抓取一起挡住。
    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notifyNewPapers(count: Int, topTitle: String?) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "发现 \(count) 篇新论文"
        content.body = topTitle.map { "当前最高分：\($0)" } ?? "打开查看评分排序"
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier,
                                           content: content, trigger: nil)
        try? await center.add(request)
    }
}

// MARK: - 格式化

enum DisplayFormat {

    static func score(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func dimension(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    /// 列表 chip 用的紧凑写法。
    ///
    /// 三位小数在列表里纯属浪费：正文列宽度只够放两三个 chip，
    /// 一位小数省下的宽度足够多塞一个。详细信息在详情页里仍是三位。
    static func dimensionCompact(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// 维度中文名（与 Python `history.DIM_LABELS` 一致）。
    static func dimensionLabel(_ key: String) -> String {
        DimensionLabels.label(key)
    }
}
