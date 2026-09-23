//
//  Keywords.swift
//  PaperScraperCore
//
//  词表资源：与 Python `evaluator.py` 顶部的常量**逐项对应**。
//
//  ⚠️ 顺序敏感
//  -----------
//  `topicKeywords` 必须保持与 Python dict 字面量完全相同的顺序：`_topic_score`
//  是逐项累加浮点数，而浮点加法不满足结合律，换顺序会让总分在最低位上漂移。
//  其余词表只做 contains / max / 计数，顺序无关。
//
//  GoldenParityTests 会拿 golden.json 里的词表与本文件做逐项比对，
// 防止人工转录出错。
//

import Foundation

public enum Keywords {

    // MARK: - 标题

    public static let titleMethodWords: [String] = [
        "benchmark", "framework", "evaluation", "rethinking", "efficient",
        "robust", "scalable", "unified", "adaptive", "hierarchical",
        "understanding", "exploring", "analysis", "study", "empirical",
        "systematic", "survey", "toward", "towards", "beyond",
    ]

    public static let titleTemplatePhrases: [String] = [
        "is all you need", "all you need", "a survey of",
    ]

    // MARK: - 主题热度（顺序敏感：见文件头说明）

    /// 键为关键词、值为热度权重。累加顺序即此数组顺序。
    public static let topicKeywords: [(keyword: String, weight: Double)] = [
        ("llm", 1.0), ("large language model", 1.0), ("language model", 0.7),
        ("agent", 0.9), ("multi-agent", 0.9), ("agentic", 0.9),
        ("rag", 0.9), ("retrieval-augmented", 0.9), ("retrieval augmented", 0.9),
        ("reasoning", 0.8), ("chain-of-thought", 0.8), ("cot", 0.5),
        ("diffusion", 0.8), ("multimodal", 0.8), ("omni", 0.7),
        ("benchmark", 0.7), ("evaluation", 0.6),
        ("safety", 0.7), ("alignment", 0.7), ("jailbreak", 0.7), ("backdoor", 0.7),
        ("quantization", 0.7), ("distillation", 0.7), ("fine-tuning", 0.6),
        ("federated", 0.7), ("privacy", 0.7), ("differential privacy", 0.8),
        ("medical", 0.7), ("clinical", 0.7), ("health", 0.6),
        ("speech", 0.6), ("asr", 0.6), ("audio", 0.6), ("vision", 0.6),
        ("code", 0.6), ("software engineering", 0.6),
        ("knowledge graph", 0.7), ("graph", 0.5),
        ("reinforcement learning", 0.7),
        ("self-improvement", 0.8), ("self-evolution", 0.8),
        ("transformer", 0.6), ("attention", 0.5),
        ("gui", 0.7), ("cyber", 0.6), ("security", 0.7),
        ("finance", 0.6), ("financial", 0.6),
        ("robot", 0.6), ("embodied", 0.7),
        ("inference", 0.6), ("serving", 0.6),
        ("kv cache", 0.7), ("gpu", 0.6), ("kernel", 0.6),
        ("watermark", 0.6), ("unlearning", 0.7),
    ]

    /// 便于按键查权重（不用于累加，累加请用 `topicKeywords` 数组）。
    public static let topicKeywordWeights: [String: Double] =
        Dictionary(uniqueKeysWithValues: topicKeywords.map { ($0.keyword, $0.weight) })

    // MARK: - 发表场所

    public static let venueTopTier: [String] = [
        "neurips", "nips", "icml", "iclr", "acl", "emnlp", "naacl", "coling",
        "cvpr", "iccv", "eccv", "aaai", "ijcai", "acm mm", "kdd", "sigir",
        "www", "wsdm", "icde", "vldb", "sigmod", "osdi", "sosp", "isca",
        "micro", "asplos", "hpca", "sc", "nature", "science", "cell",
        "jmlr", "tpami", "tkde", "ieee transactions", "acm transactions",
        "ieee internet computing", "ieee lcss",
    ]

    public static let venueWorkshop: [String] = [
        "workshop", "findings", "symposium", "poster", "demo",
    ]

    /// 只有文本出现这些词，venue 维度才会参与打分。
    public static let venueSignalWords: [String] = [
        "accepted", "published", "proceedings", "conference",
        "journal", "findings", "workshop",
    ]

    // MARK: - 机构

    public static let institutionKeywords: [String] = [
        "google", "deepmind", "openai", "microsoft", "meta", "apple", "amazon",
        "nvidia", "ibm", "adobe", "salesforce", "bytedance", "alibaba",
        "tencent", "baidu", "huawei", "xiaomi", "tsinghua", "peking",
        "zhejiang", "shanghai jiao tong", "stanford", "mit", "berkeley",
        "cmu", "carnegie mellon", "oxford", "cambridge", "eth", "epfl",
        "max planck", "kaist", "yonsei", "seoul national", "tokyo",
    ]

    // MARK: - 机构分层（"机构"维度用）

    /// 第一档：公认的顶尖机构。
    ///
    /// ⚠️ 匹配时必须用**词边界**（`KeywordMatcher.matches`），不能用 `contains`。
    /// 反例：`"mit"` 会命中 `"Smith College"`，`"meta"` 会命中 `"metabolic"`，
    /// `"eth"` 会命中 `"ethics"` —— 机构名里这类子串太常见了。
    public static let institutionTopTier: [String] = [
        "google", "deepmind", "openai", "anthropic", "microsoft", "meta",
        "apple", "nvidia", "stanford", "mit", "massachusetts institute of technology",
        "berkeley", "uc berkeley", "carnegie mellon", "cmu", "oxford",
        "cambridge", "eth zurich", "epfl", "tsinghua", "peking", "princeton",
        "harvard", "caltech", "california institute of technology",
    ]

    /// 第二档：知名机构（大厂研究院与一流高校）。
    public static let institutionStrongTier: [String] = [
        "amazon", "ibm", "adobe", "salesforce", "bytedance", "alibaba",
        "tencent", "baidu", "huawei", "xiaomi", "samsung", "naver", "kakao",
        "allen institute", "max planck", "kaist", "seoul national", "tokyo",
        "zhejiang", "shanghai jiao tong", "fudan", "university of washington",
        "cornell", "columbia", "ucla", "uc san diego", "uc davis",
        "new york university", "university of toronto", "mila",
        "university of melbourne", "university of sydney", "monash",
        // 下面几条是按真机抓到的机构名补的（原本只能拿到中性分 0.5）
        "university of california", "purdue", "rensselaer",
        "georgia institute of technology", "university of illinois",
        "university of michigan", "university of chicago",
        "university of texas", "nanyang technological",
        "chinese university of hong kong", "hong kong university of science",
        "sun yat-sen", "nec laboratories", "nec",
    ]

    // MARK: - 摘要信号词

    public static let abstractMethodWords: [String] = [
        "we propose", "we introduce", "we present", "we develop",
        "we design", "we show", "framework", "method", "approach",
        "algorithm", "architecture",
    ]

    public static let abstractResultWords: [String] = [
        "achieve", "improve", "outperform", "state-of-the-art",
        "sota", "surpass", "reduce", "increase", "gain", "accuracy",
    ]

    public static let abstractSignalWords: [String] = [
        "benchmark", "dataset", "evaluation", "experiment", "ablation",
    ]

    /// 倍数/加速表述的候选词（对应 Python 正则里的 `(x|fold|times)`）。
    public static let multiplierTokens: [String] = ["x", "fold", "times"]
}
