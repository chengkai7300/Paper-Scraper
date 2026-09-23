//
//  TranslationEngine.swift
//  PaperScraper
//
//  可插拔的翻译引擎。
//
//  为什么要重构
//  ------------
//  系统 Translation 框架是通用 NMT，对专业文献的**术语**没有约束能力：
//  "ablation study"、"attention"、"ground truth" 这类词很容易译得不准或前后不一致。
//  这不是它的 bug，而是通用机器翻译的固有短板。
//
//  通行解法（沉浸式翻译、zotero-pdf-translate 等插件的做法）不是换一个更好的
//  NMT 模型，而是：**让引擎可插拔 + 用 LLM + 注入术语表**。
//  本文件落实的正是这三点，其中术语表是提升专业文献准确率最有效的手段。
//
//  三种引擎
//  --------
//   1. AppleIntelligenceEngine —— 端侧大模型（iOS 26+，FoundationModels 框架）
//      免费、离线、保护隐私，可注入术语表。**默认**。
//   2. OpenAICompatibleEngine  —— 任意 OpenAI 兼容接口（OpenAI / DeepSeek /
//      Kimi / 智谱 / 通义 / 本地 Ollama…）。质量上限最高，需要用户自己的 Key。
//
//  为什么移除了系统 Translation 框架
//  --------------------------------
//  上面的两个引擎都能注入术语表，专业文献质量都严格优于通用 NMT；
//  同时保留它会带来两套完全不同的执行路径（一个必须由 SwiftUI 的
//  `.translationTask` 驱动、一个可以直接 await），得不偿失。
//

import Foundation
import FoundationModels

// MARK: - 术语表

/// 双语术语表。**这是提升专业文献翻译准确率最关键的机制**：
/// 与其指望模型自己选对术语，不如把领域惯用译法直接喂给它。
struct TranslationGlossary: Sendable {

    /// 内置的 AI / 机器学习常用术语。
    static let builtIn: [(String, String)] = [
        ("attention", "注意力"),
        ("self-attention", "自注意力"),
        ("cross-attention", "交叉注意力"),
        ("embedding", "嵌入"),
        ("token", "词元"),
        ("tokenizer", "分词器"),
        ("fine-tuning", "微调"),
        ("pre-training", "预训练"),
        ("prompt", "提示词"),
        ("inference", "推理"),
        ("ablation study", "消融实验"),
        ("benchmark", "基准测试"),
        ("state-of-the-art", "当前最优"),
        ("retrieval-augmented generation", "检索增强生成"),
        ("chain-of-thought", "思维链"),
        ("hallucination", "幻觉"),
        ("quantization", "量化"),
        ("knowledge distillation", "知识蒸馏"),
        ("diffusion model", "扩散模型"),
        ("multimodal", "多模态"),
        ("reinforcement learning", "强化学习"),
        ("reward model", "奖励模型"),
        ("alignment", "对齐"),
        ("robustness", "鲁棒性"),
        ("generalization", "泛化"),
        ("latent space", "潜空间"),
        ("encoder", "编码器"),
        ("decoder", "解码器"),
        ("gradient descent", "梯度下降"),
        ("batch size", "批大小"),
        ("learning rate", "学习率"),
        ("overfitting", "过拟合"),
        ("regularization", "正则化"),
        ("zero-shot", "零样本"),
        ("few-shot", "少样本"),
        ("in-context learning", "上下文学习"),
        ("throughput", "吞吐量"),
        ("latency", "延迟"),
        ("ground truth", "真实标签"),
        ("precision", "精确率"),
        ("recall", "召回率"),
        ("classifier", "分类器"),
        ("baseline", "基线"),
        ("dataset", "数据集"),
        ("annotation", "标注"),
        ("supervised", "有监督"),
        ("unsupervised", "无监督"),
        ("long context", "长上下文"),
    ]

    /// 内置术语 + 用户自定义（用户项优先，便于覆盖内置译法）。
    var entries: [(String, String)]

    init(userEntries: [(String, String)] = []) {
        var merged: [String: String] = [:]
        for (term, translation) in Self.builtIn { merged[term.lowercased()] = translation }
        for (term, translation) in userEntries {
            merged[term.trimmingCharacters(in: .whitespaces).lowercased()] = translation
        }
        entries = merged
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// 解析设置页里的多行文本（`英文 => 中文`，一行一条）。
    static func parseUserEntries(_ text: String) -> [(String, String)] {
        text
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let parts = line.components(separatedBy: "=>")
                guard parts.count >= 2 else { return nil }
                let term = parts[0].trimmingCharacters(in: .whitespaces)
                let translation = parts[1...].joined(separator: "=>")
                    .trimmingCharacters(in: .whitespaces)
                guard !term.isEmpty, !translation.isEmpty else { return nil }
                return (term, translation)
            }
    }

    static func format(_ entries: [(String, String)]) -> String {
        entries.map { "\($0.0) => \($0.1)" }.joined(separator: "\n")
    }

    var promptFragment: String {
        guard !isEmpty else { return "" }
        return entries.map { "- \($0.0) => \($0.1)" }.joined(separator: "\n")
    }
}

// MARK: - 提示词

/// 面向学术文献的翻译指令。
///
/// 这几条要求都是针对通用 NMT 的具体缺陷设计的：
///   * 术语表        -> 解决术语不准、前后不一致
///   * 保留英文原名   -> 解决方法名/数据集名被硬译（"LoRA" 变成"低秩适配器"）
///   * 原样保留公式   -> 解决数学符号被改写
///   * 禁止追加解释   -> 解决模型自说自话
enum TechnicalTranslationPrompt {

    static func instructions(glossary: TranslationGlossary) -> String {
        var lines = [
            "你是计算机科学领域的专业学术翻译，负责把英文学术文本翻译成简体中文。",
            "",
            "必须遵守以下规则：",
            "1. 术语准确：使用机器学习、人工智能领域的标准中文术语。",
            "2. 方法名、模型名、数据集名、框架名、作者名保留英文原文，不要硬译"
                + "（例如 Transformer、LoRA、RAG、GPT-4、ImageNet 保持原样）。",
            "3. 数学符号、公式、变量名、引用标记（如 [1]、\\cite{}）、"
                + "代码标识符、URL 一律原样保留，不做翻译或改写。",
            "4. 只输出译文本身：不要添加解释、译者注、前言、后记，"
                + "也不要输出原文或\"译文：\"之类的前缀。",
            "5. 保持原文的句子结构与段落划分，不要合并或拆分段落。",
            "6. 若某个术语在中文语境下习惯保留英文，则保留英文。",
            "7. 若下方术语表与以上规则冲突，以术语表为准。",
        ]

        if !glossary.isEmpty {
            lines.append("")
            lines.append("术语表（原文 => 规范译法），必须严格遵守：")
            lines.append(glossary.promptFragment)
        }

        return lines.joined(separator: "\n")
    }

    /// 组装单段文本的完整提示词。
    ///
    /// - Parameter context: 已翻译的标题。把它作为上下文喂给模型，
    ///   能显著提升标题与摘要之间的**术语一致性**。
    static func prompt(text: String, kind: TextKind, context: String?) -> String {
        var lines: [String] = []

        if let context, !context.isEmpty {
            switch kind {
            case .abstract:
                lines.append("以下是这篇论文的标题译文，翻译摘要时请保持术语与之一致：")
                lines.append(context)
                lines.append("")
            case .title:
                break
            }
        }

        switch kind {
        case .title:
            lines.append("请翻译下面这段论文标题：")
        case .abstract:
            lines.append("请翻译下面这段论文摘要：")
        }
        lines.append("")
        lines.append(text)

        return lines.joined(separator: "\n")
    }

    enum TextKind {
        case title
        case abstract
    }
}

// MARK: - 引擎协议

enum TranslationEngineError: LocalizedError {
    case notConfigured(String)
    case unavailable(String)
    case emptyResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let detail): "翻译引擎未配置：\(detail)"
        case .unavailable(let detail): "翻译引擎不可用：\(detail)"
        case .emptyResponse: "翻译引擎返回了空结果"
        case .httpStatus(let code, let body):
            "翻译接口返回 HTTP \(code)\(body.isEmpty ? "" : "：\(body)")"
        }
    }
}

/// 翻译引擎只需做好一件事：把一段文本译成中文。
///
/// 标题 / 摘要的顺序编排、缓存的读写、批量的并发控制都由上层统一负责，
/// 这样新增引擎的成本很低。
protocol TranslationEngine: Sendable {

    /// 展示给用户的名字，会随译文一起记录，便于事后判断质量来源。
    var displayName: String { get }

    func translate(_ text: String,
                   kind: TechnicalTranslationPrompt.TextKind,
                   context: String?) async throws -> String
}

// MARK: - Apple Intelligence（端侧大模型）

@available(iOS 26.0, *)
struct AppleIntelligenceEngine: TranslationEngine {

    let glossary: TranslationGlossary

    var displayName: String { "Apple Intelligence（端侧）" }

    /// 端侧模型是否就绪（未开启 Apple Intelligence 或设备不支持时为 false）。
    static var systemAvailability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "此设备不支持 Apple Intelligence"
            case .appleIntelligenceNotEnabled: return "尚未在系统设置中开启 Apple Intelligence"
            case .modelNotReady: return "端侧模型仍在下载或准备中"
            @unknown default: return "端侧模型不可用"
            }
        @unknown default:
            return "端侧模型不可用"
        }
    }

    func translate(_ text: String,
                   kind: TechnicalTranslationPrompt.TextKind,
                   context: String?) async throws -> String {
        guard Self.unavailableReason == nil else {
            throw TranslationEngineError.unavailable(Self.unavailableReason ?? "未知原因")
        }

        let session = LanguageModelSession(
            instructions: TechnicalTranslationPrompt.instructions(glossary: glossary))
        let prompt = TechnicalTranslationPrompt.prompt(text: text, kind: kind,
                                                      context: context)

        do {
            let response = try await session.respond(to: prompt)
            let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw TranslationEngineError.emptyResponse }
            return output
        } catch {
            // 端侧模型上下文有限，长摘要可能超限。LanguageModelError 是 iOS 27+
            // 才有的类型，而端侧模型本身 iOS 26 就可用，所以这里做条件判断，
            // 不为了一处错误分类把整个引擎的可用性门槛抬到 27。
            if #available(iOS 27.0, *),
               let modelError = error as? LanguageModelError,
               case .contextSizeExceeded = modelError {
                throw TranslationEngineError.unavailable(
                    "文本超出端侧模型上下文，建议改用云端引擎")
            }
            throw error
        }
    }
}

// MARK: - OpenAI 兼容接口

/// 任意 OpenAI 兼容的 `/chat/completions` 接口。
///
/// 之所以做成「兼容接口」而不是绑定某一家：这类翻译插件的生态就是这样——
/// OpenAI、DeepSeek、Kimi、智谱、通义、本地 Ollama / LM Studio 全部走同一套协议，
/// 用户只要填 Base URL + 模型名 + Key 就能切换，质量上限取决于所选模型。
struct OpenAICompatibleEngine: TranslationEngine {

    let baseURL: String
    let model: String
    let apiKey: String
    let glossary: TranslationGlossary
    let timeout: TimeInterval

    init(baseURL: String, model: String, apiKey: String,
         glossary: TranslationGlossary, timeout: TimeInterval = 60) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.model = model
        self.apiKey = apiKey
        self.glossary = glossary
        self.timeout = timeout
    }

    var displayName: String { "云端模型（\(model)）" }

    func translate(_ text: String,
                   kind: TechnicalTranslationPrompt.TextKind,
                   context: String?) async throws -> String {
        guard !apiKey.isEmpty else {
            throw TranslationEngineError.notConfigured("缺少 API Key")
        }
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw TranslationEngineError.notConfigured("Base URL 无效：\(baseURL)")
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system",
                 "content": TechnicalTranslationPrompt.instructions(glossary: glossary)],
                ["role": "user",
                 "content": TechnicalTranslationPrompt.prompt(text: text, kind: kind,
                                                              context: context)],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationEngineError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?
                .prefix(200).trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw TranslationEngineError.httpStatus(http.statusCode, detail)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw TranslationEngineError.emptyResponse }

        let output = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw TranslationEngineError.emptyResponse }
        return output
    }
}

// MARK: - 引擎选择

/// 云端服务的预置参数。用户仍可自由改 Base URL 与模型名。
struct TranslationProvider: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var note: String

    static let presets: [TranslationProvider] = [
        TranslationProvider(id: "openai", name: "OpenAI",
                            baseURL: "https://api.openai.com/v1",
                            model: "gpt-4o-mini",
                            note: "通用质量稳定"),
        TranslationProvider(id: "deepseek", name: "DeepSeek",
                            baseURL: "https://api.deepseek.com/v1",
                            model: "deepseek-chat",
                            note: "中文表达自然，性价比高"),
        TranslationProvider(id: "moonshot", name: "Moonshot / Kimi",
                            baseURL: "https://api.moonshot.cn/v1",
                            model: "moonshot-v1-8k",
                            note: "长文本处理较好"),
        TranslationProvider(id: "zhipu", name: "智谱 GLM",
                            baseURL: "https://open.bigmodel.cn/api/paas/v4",
                            model: "glm-4-flash",
                            note: "有免费额度"),
        TranslationProvider(id: "dashscope", name: "阿里百炼 / 通义",
                            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                            model: "qwen-plus",
                            note: "中文术语较弱项的补充"),
        TranslationProvider(id: "ollama", name: "本地 Ollama / LM Studio",
                            baseURL: "http://localhost:11434/v1",
                            model: "qwen2.5:7b",
                            note: "完全离线；需填运行服务的那台机器的局域网 IP，"
                                + "localhost 指的是手机自己"),
        TranslationProvider(id: "custom", name: "自定义",
                            baseURL: "", model: "", note: "自填 Base URL 与模型名"),
    ]
}

enum TranslationEngineKind: String, CaseIterable, Identifiable, Sendable {
    case appleIntelligence
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence（端侧，免费）"
        case .openAICompatible: "云端模型（需 API Key）"
        }
    }
}
