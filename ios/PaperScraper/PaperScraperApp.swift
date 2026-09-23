//
//  PaperScraperApp.swift
//  PaperScraper
//

import PaperScraperCore
import SwiftUI
import UIKit

/// 仅用于在"启动完成之前"注册后台任务处理器。
///
/// 为什么不用 SwiftUI 的 `.backgroundTask(.appRefresh(...))`：
/// 那个修饰符会在场景创建时才注册，实测已经晚于启动完成，直接触发
/// BGTaskScheduler 的
/// `All launch handlers must be registered before application finishes launching`
/// 断言并崩溃。AppDelegate 的回调时机才是正确的。
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefresh.registerHandler {
            await AppModel.shared.performBackgroundRefresh()
        }

        // 论文插图动辄几百 KB，一篇十几张。系统默认的 URLCache 只有 ~10MB 磁盘，
        // 看几张就会被淘汰、反复重下。这里显式调大，交给系统管理淘汰策略。
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024)

        // 预热网络状态监视器：首次路径回调有延迟，而首屏预取要用这个结果。
        // 这里主动碰一下单例，让它在启动阶段就开始监听 ——
        // 等到真正需要判断时（抓完列表之后），状态早就到了。
        _ = NetworkPolicy.shared.isResolved
        return true
    }
}

@main
struct PaperScraperApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
