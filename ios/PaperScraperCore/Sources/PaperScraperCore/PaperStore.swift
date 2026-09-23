//
//  PaperStore.swift
//  PaperScraperCore
//
//  元数据持久化：`papers_metadata.json` 的读写与备份。
//
//  与 Python 保持一致
//  ------------------
//    * 文件名、备份文件名（`.backup.json`）与 Python 侧完全相同；
//    * 仍以"一个 JSON 数组"为存储格式，保证文件在两端可互换；
//    * 编码用 `.sortedKeys`，让 diff 稳定（Python 用 indent=4，Swift 用 2 空格，
//      缩进不同但语义等价）。
//
//  iOS 特有的一处细节
//  ------------------
//  写入时显式设置 **文件保护等级**。默认的 `NSFileProtectionComplete` 会在设备
//  锁屏后让文件不可读写 —— 而"后台刷新"恰恰只会在锁屏时发生。因此这里降级为
//  `completeUntilFirstUserAuthentication`，否则后台任务会以"文件不存在/无权限"
//  的形式静默失败。
//

import Foundation

public enum PaperStore {

    public static let defaultFileName = "papers_metadata.json"

    public enum StoreError: LocalizedError {
        case encodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .encodingFailed(let detail): "元数据编码失败：\(detail)"
            }
        }
    }

    // MARK: 路径

    /// 默认存储位置：App 沙箱的 Documents 目录。
    public static func defaultURL() -> URL {
        documentsDirectory().appendingPathComponent(defaultFileName)
    }

    public static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// `papers_metadata.json` -> `papers_metadata.backup.json`（与 Python 一致）。
    public static func backupURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent(stem + ".backup.json")
    }

    // MARK: 读写

    public static func load(from url: URL) throws -> [Paper] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([Paper].self, from: data)
    }

    public static func save(_ papers: [Paper], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let data: Data
        do {
            data = try encoder.encode(papers)
        } catch {
            throw StoreError.encodingFailed(String(describing: error))
        }

        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        }

        try data.write(to: url, options: [.atomic])

        // 后台写入通常发生在锁屏状态，必须放宽文件保护等级
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }

    /// 复制一份备份，返回备份路径（对应 Python `history.save_backup`）。
    @discardableResult
    public static func backup(of url: URL) throws -> URL {
        let target = backupURL(for: url)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    /// 存储占用概览，用于设置页展示与"清理 PDF"入口。
    public static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}

// MARK: - 评分档位持久化

/// 同一份元数据可以按不同权重档位评估（用于对比）。档位定义在这里，
/// 与 Python 侧 `test_weights.py` / `tools/export_golden.py` 的用词保持一致。
public struct WeightPreset: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var weights: [String: Double]

    public init(name: String, displayName: String, weights: [String: Double]) {
        self.name = name
        self.displayName = displayName
        self.weights = weights
    }

    /// 当前默认权重（abstract 已由 0.30 下调至 0.15）。
    public static let current = WeightPreset(
        name: "default",
        displayName: "当前权重",
        weights: HeuristicEvaluator.defaultWeights)

    /// 调整前的旧权重，用于回溯对比。
    public static let legacy = WeightPreset(
        name: "old",
        displayName: "旧权重（abstract 0.30）",
        weights: ["title": 0.15, "author": 0.15, "abstract": 0.30,
                  "recency": 0.10, "topic": 0.30])

    public static let all: [WeightPreset] = [.current, .legacy]
}
