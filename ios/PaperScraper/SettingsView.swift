//
//  SettingsView.swift
//  PaperScraper
//
//  设置页：取代 Python 的命令行参数与环境变量。
//
//  对应关系
//  --------
//    --query / --max / --sort   -> 抓取分组
//    权重 / --external / --llm  -> 评分分组（含 Keychain 里的 API Key）
//    --revaluate                -> 数据分组（立即增量重评）
//

import PaperScraperCore
import SwiftUI

struct SettingsView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyDraft = ""
    @State private var translationKeyDraft = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        @Bindable var model = model

        Form {
            // MARK: 抓取
            // MARK: 评分
            Section {
                Picker("权重档位", selection: $model.settings.weightPresetName) {
                    ForEach(WeightPreset.all) { preset in
                        Text(preset.displayName).tag(preset.name)
                    }
                }

                Toggle("外部引用增强", isOn: $model.settings.useExternal)

                Toggle("LLM 语义评分", isOn: $model.settings.useLLM)

                if model.settings.useLLM {
                    TextField("Base URL", text: $model.settings.llmBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    TextField("模型", text: $model.settings.llmModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("API Key", text: $apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("评分")
            } footer: {
                Text("· 改权重或开关后，历史评分不再是同一口径，返回列表会提示重新评估。\n"
                     + "· 外部引用增强走 Semantic Scholar 匿名配额，可能返回 429；"
                     + "失败时静默跳过，不影响其他维度。\n"
                     + "· API Key 只存在本机 Keychain，不写入元数据，也不同步到 iCloud。\n"
                     + "· 权重与配置指纹与 Python 版逐字节一致，"
                     + "同一个 papers_metadata.json 可以两端互换。")
            }

            // MARK: 后台
            Section {
                Toggle("启用后台刷新", isOn: $model.settings.backgroundRefreshEnabled)
                    .onChange(of: model.settings.backgroundRefreshEnabled) { _, enabled in
                        BackgroundRefresh.schedule(enabled: enabled)
                    }

                Toggle("发现新论文时通知", isOn: $model.settings.notifyOnNewPapers)
                    .onChange(of: model.settings.notifyOnNewPapers) { _, enabled in
                        // 用户主动打开时才申请授权，避免弹窗挡在启动路径上
                        guard enabled else { return }
                        Task { await LocalNotifier.requestAuthorization() }
                    }
            } header: {
                Text("后台")
            } footer: {
                Text("⚠️ iOS 由系统决定后台任务的执行时机，不保证按时执行。"
                     + "系统会参考你的使用习惯来安排，长期不打开 App 时可能长时间不触发。"
                     + "因此这里定位是「有机会就更新」，而不是「每天定时抓取」。")
            }

            // MARK: 数据
            Section {
                LabeledContent("论文记录", value: "\(model.papers.count) 篇")
                LabeledContent("已完成评分", value: "\(model.scoredCount) 篇")
                if model.unscoredCount > 0 {
                    LabeledContent("待评分", value: "\(model.unscoredCount) 篇")
                }
                LabeledContent("存储占用", value: DisplayFormat.byteCount(model.storageBytes))

                Button {
                    Task { await model.reevaluate() }
                } label: {
                    Label("立即增量重评", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                .disabled(model.phase.isBusy || model.papers.isEmpty)

                Button {
                    Task { await model.reevaluate(force: true) }
                } label: {
                    Label("强制全量重算", systemImage: "arrow.clockwise.circle")
                }
                .disabled(model.phase.isBusy || model.papers.isEmpty)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("清空本地记录", systemImage: "trash")
                }
                .disabled(model.papers.isEmpty)
            } header: {
                Text("数据")
            } footer: {
                Text("重评前会自动生成 papers_metadata.backup.json 备份，"
                     + "与 Python 版的 --revaluate 行为一致。")
            }

            // MARK: 中文翻译
            Section {
                Picker("翻译引擎", selection: $model.settings.translationEngine) {
                    ForEach(TranslationEngineKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }

                switch model.translationSetup() {
                case .ready(let engine):
                    LabeledContent("当前引擎", value: engine.displayName)
                case .unavailable(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if translationEngineKind == .openAICompatible {
                    Picker("服务商", selection: $model.settings.translationProviderID) {
                        ForEach(TranslationProvider.presets) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .onChange(of: model.settings.translationProviderID) { _, newValue in
                        guard let preset = TranslationProvider.presets
                            .first(where: { $0.id == newValue }),
                            preset.id != "custom" else { return }
                        model.settings.translationBaseURL = preset.baseURL
                        model.settings.translationModel = preset.model
                    }

                    if let note = currentProviderNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }

                    TextField("Base URL", text: $model.settings.translationBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    TextField("模型", text: $model.settings.translationModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("API Key", text: $translationKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("中文翻译")
            } footer: {
                Text("通用机器翻译对专业文献的**术语**没有约束能力，"
                     + "所以这里改用「可注入术语表的大模型」。\n"
                     + "· 端侧引擎：免费、离线、不联网，需要 iOS 26 且已开启 Apple Intelligence。\n"
                     + "· 云端引擎：翻译质量上限更高，需自备 API Key（与打分用的 Key 相互独立）。\n"
                     + "· 无论哪个引擎，都会带上下面的术语表与学术翻译指令。")
            }

            // MARK: 术语表
            Section {
                TextField("每行一条，格式：英文 => 中文",
                          text: $model.settings.translationGlossaryText,
                          axis: .vertical)
                    .lineLimit(4...12)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                LabeledContent("内置术语", value: "\(TranslationGlossary.builtIn.count) 条")
                LabeledContent("生效术语", value: "\(model.glossary.entries.count) 条")
            } header: {
                Text("术语表")
            } footer: {
                Text("这是提升专业文献准确率最有效的手段：直接把领域惯用译法喂给模型，"
                     + "比指望它自己选对术语可靠得多。\n"
                     + "已内置 AI/机器学习常用术语，你在下面填写的会**覆盖**同名内置项。\n"
                     + "示例：ablation study => 消融实验")
            }

            // MARK: 译文缓存
            Section {
                LabeledContent("已缓存译文", value: "\(model.translationCount) 篇")

                Button(role: .destructive) {
                    model.clearTranslations()
                } label: {
                    Label("清除译文缓存", systemImage: "trash")
                }
                .disabled(model.translationCount == 0)
            } footer: {
                Text("译文会缓存到本地，同一篇不会重复翻译；"
                     + "换了引擎或改了术语表后，可在详情页点「重新翻译」覆盖单篇。\n"
                     + "列表页「更多」菜单可批量翻译排名靠前的标题，摘要在详情页按需翻译。")
            }

            // MARK: 图表缓存
            Section {
                LabeledContent("已缓存图表", value: "\(model.figureCacheCount) 篇")
                LabeledContent("已栅格化矢量图", value: "\(model.vectorCacheCount) 张")

                Picker("首屏预取篇数", selection: $model.settings.keyFigurePrefetchLimit) {
                    Text("关闭").tag(0)
                    Text("5 篇").tag(5)
                    Text("10 篇").tag(10)
                    Text("20 篇").tag(20)
                    Text("50 篇").tag(50)
                }

                Toggle("仅 Wi-Fi 下首屏预取", isOn: $model.settings.wifiOnlyPrefetch)

                Button(role: .destructive) {
                    model.clearFigures()
                } label: {
                    Label("清除图表与图片缓存", systemImage: "trash")
                }
                .disabled(model.figureCacheCount == 0)
            } header: {
                Text("图表")
            } footer: {
                Text("图表从 arXiv 的 **HTML 版本**（`arxiv.org/html/<id>`）提取，"
                     + "自带图注；实测约 90% 的论文有该版本。\n"
                     + "图注里附的「Figure 1」是论文自己的图号；没有图号的图会标成「未编号插图」，"
                     + "以免和正文图号混淆。\n"
                     + "· 首屏会按排名预取前几篇的核心图；**其余行在滚动到时自动补**，"
                     + "所以在快速滑动时缩略图会依次出现。\n"
                     + "· 每张缩略图需要一次约 300KB 的 HTML 抓取，请求间隔 1.5 秒。\n"
                     + "· 仅首屏预取受上面的 Wi-Fi 开关限制；滚动到你眼前的行属于「你主动在看」，"
                     + "不受限制。\n"
                     + "· 图片本体由系统的 URLCache 管理（上限 256 MB），会自动淘汰。\n"
                     + "· 矢量图（SVG 占实测一半）由 WebKit 栅格化后存到沙箱，"
                     + "首次查看会多等一两秒。\n"
                     + "· 没有 HTML 版的论文取不到图，详情页会说明并给出 PDF 入口。")
            }

            // MARK: 列表展示
            Section {
                ForEach(DimensionLabels.allKeys, id: \.self) { key in
                    Toggle(isOn: binding(for: key)) {
                        HStack(spacing: 8) {
                            Text(DimensionLabels.label(key))
                            Text(key)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Button {
                    model.settings.displayedDimensionKeys = DimensionLabels.allKeys
                } label: {
                    Label("全选", systemImage: "checkmark.circle")
                }
                .disabled(model.settings.displayedDimensionKeys.count
                          == DimensionLabels.allKeys.count)

                Button {
                    model.settings.displayedDimensionKeys = []
                } label: {
                    Label("全部隐藏", systemImage: "circle.slash")
                }
                .disabled(model.settings.displayedDimensionKeys.isEmpty)
            } header: {
                Text("列表展示的评分维度")
            } footer: {
                Text("控制论文列表每行显示哪些评分维度，顺序即这里列出的顺序。\n"
                     + "· 「场所」和「机构」是「有条件参与」的维度：论文没有相应数据时"
                     + "本来就不会出现，即使勾选也不会显示。\n"
                     + "· 列表里的分值保留两位小数（详情页仍是三位）——"
                     + "正文列宽度有限，省下的宽度可以多放一个维度。\n"
                     + "· 全部隐藏时列表只显示日期。")
            }

            Section {
                TextField("关键词", text: $model.settings.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Stepper(value: $model.settings.maxResults, in: 10...500, step: 10) {
                    LabeledContent("抓取上限", value: "\(model.settings.maxResults) 篇")
                }

                Toggle("按提交时间倒序", isOn: $model.settings.sortBySubmittedDate)
            } header: {
                Text("抓取")
            } footer: {
                Text("对应 --query / --max / --sort。超出单页上限会自动分页，"
                     + "请求之间保持间隔以遵守 arXiv 的 API 使用规范。")
            }

            // MARK: 当前口径
            Section {
                LabeledContent("关键词表", value: "\(Keywords.topicKeywords.count) 项")
                LabeledContent("配置指纹", value: model.evaluator.configKey)
                LabeledContent("权重", value: Self.formatWeights(model.evaluator.heuristic.weights))
            } header: {
                Text("当前口径")
            } footer: {
                Text("评分内核由 PaperScraperCore 提供，已通过与 Python 版的 "
                     + "100 条金标准对拍测试与 150 条真实历史记录兼容性校验。")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .task {
            apiKeyDraft = KeychainStore.read(KeychainStore.llmAPIKeyName) ?? ""
            translationKeyDraft = KeychainStore.read(KeychainStore.translationAPIKeyName) ?? ""
        }
        .onChange(of: apiKeyDraft) { _, newValue in
            model.updateAPIKey(newValue)
        }
        .onChange(of: translationKeyDraft) { _, newValue in
            model.updateTranslationKey(newValue)
        }
        .confirmationDialog("确定清空本地全部记录？",
                            isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("清空", role: .destructive) { model.deleteAllRecords() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除 papers_metadata.json 及其备份，操作不可撤销。")
        }
    }

    private var translationEngineKind: TranslationEngineKind {
        TranslationEngineKind(rawValue: model.settings.translationEngine)
            ?? .appleIntelligence
    }

    private var currentProviderNote: String? {
        TranslationProvider.presets
            .first { $0.id == model.settings.translationProviderID }?
            .note
    }

    /// 某个维度是否在列表里显示。
    ///
    /// 用自定义 binding 而不是直接绑定数组元素：`Toggle` 需要一个 `Bool` 的
    /// binding，而数据源是有序数组（顺序决定列表里的展示顺序）。
    /// 增删时保持数组有序，这样"勾选顺序"不会打乱展示顺序。
    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { model.settings.displayedDimensionKeys.contains(key) },
            set: { isOn in
                var keys = model.settings.displayedDimensionKeys
                if isOn {
                    guard !keys.contains(key) else { return }
                    // 按 DimensionLabels.allKeys 的固定顺序插入，避免顺序随点击变化
                    let order = DimensionLabels.allKeys
                    keys.append(key)
                    keys.sort { (order.firstIndex(of: $0) ?? 0)
                        < (order.firstIndex(of: $1) ?? 0) }
                } else {
                    keys.removeAll { $0 == key }
                }
                model.settings.displayedDimensionKeys = keys
            })
    }

    private static func formatWeights(_ weights: [String: Double]) -> String {
        weights
            .sorted { $0.key < $1.key }
            .map { "\(DisplayFormat.dimensionLabel($0.key)) \(String(format: "%.2f", $0.value))" }
            .joined(separator: " / ")
    }
}
