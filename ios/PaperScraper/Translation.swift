//
//  Translation.swift
//  PaperScraper
//
//  译文的**数据与缓存**。（引擎与提示词见 `TranslationEngine.swift`。）
//
//  缓存策略
//  --------
//  翻译要调用端侧模型或云端接口，有实际耗时与费用，同一篇重复翻译没有意义，
//  因此落盘缓存，思路与评分模块的“增量评价”一致：**算过就不再算**。
//  译文会记录产出它的引擎，切换引擎后可据此提示重新翻译。
//

import Foundation

// MARK: - 目标语言

enum TranslationTarget {
    /// 简体中文。
    static let identifier = "zh-Hans"

    static var language: Locale.Language {
        Locale.Language(identifier: identifier)
    }
}

// MARK: - 译文

/// 一条论文的译文。`url` 作为缓存键，不写进结构体。
struct PaperTranslation: Codable, Hashable, Sendable {
    var title: String
    var abstract: String
    var targetLanguage: String
    var translatedAt: Date
    /// 产出译文的引擎名。可选是为了兼容早期缓存。
    var engine: String?

    var isEmpty: Bool { title.isEmpty && abstract.isEmpty }
}

// MARK: - 译文缓存

/// 译文缓存，落盘到沙箱 `Documents/translations.json`。
actor TranslationCache {

    private let fileURL: URL
    private var entries: [String: PaperTranslation] = [:]
    private var didLoad = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func all() -> [String: PaperTranslation] {
        loadIfNeeded()
        return entries
    }

    func store(_ translation: PaperTranslation, for url: String) {
        loadIfNeeded()
        entries[url] = translation
        persist()
    }

    func removeAll() {
        entries = [:]
        didLoad = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: 私有

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([String: PaperTranslation].self, from: data)) ?? [:]
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }

        try? data.write(to: fileURL, options: .atomic)
        // 与其他数据文件保持一致：后台写入时设备通常是锁屏状态
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path)
    }
}
