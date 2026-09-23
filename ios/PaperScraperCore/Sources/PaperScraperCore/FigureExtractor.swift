//
//  FigureExtractor.swift
//  PaperScraperCore
//
//  提取 arXiv 论文里的图表（图片 + 图注）。
//
//  为什么走 arXiv 原生 HTML，而不是解析 PDF 或 LaTeX 源码
//  ------------------------------------------------------
//  调研过三条路，结论如下：
//
//   1. **arXiv 原生 HTML**（`https://arxiv.org/html/<id>`）✅
//      arXiv 从 2023 年底开始为投稿生成 HTML（LaTeXML 转换）。
//      页面里的 `<figure class="ltx_figure">` 结构规整，自带 `<figcaption>` 图注，
//      图片直接是相对路径的 PNG。实测 20 篇真实样本有 18 篇可用（90%），
//      平均每篇 8.4 个图。**这是最省事、信息最全的路径。**
//
//   2. **PDF 抽取** ❌
//      `CGPDFDocument` 不暴露内嵌位图，只能整页渲染。要么自己做 XObject 解析，
//      要么退化成"把每页截成图"——前者工作量大，后者本质不是"图表"。
//      另外一篇 PDF 动辄数 MB，移动网络上不划算。
//
//   3. **LaTeX 源码包**（`/e-print/<id>`）❌
//      要解 tar、解析 `\includegraphics`、处理多文件工程，极重且极易碎。
//
//  也试过 `ar5iv.labs.arxiv.org` 作为回退源，但它对缺 HTML 的论文会返回一个
//  约 40 KB 的占位页（无 `<figure>`），不可靠，因此没有采用。
//  代价是没有 HTML 的那约 10% 论文取不到图 —— 详情页会明确说明并给出 PDF 入口。
//
//  解析方式
//  --------
//  HTML 不是格式良好的 XML，`XMLParser` 用不了；为了不引入 SwiftSoup 之类的
//  依赖，这里用受限的正则 + 手工做标签剥离与实体解码。LaTeXML 的输出结构
//  非常稳定，加上有真实样本的回归测试兜底，这个取舍是可控的。
//

import Foundation

// MARK: - 数据模型

/// 论文里的一张图。
public struct PaperFigure: Codable, Sendable, Hashable, Identifiable {
    /// 图片地址即唯一键。
    public var id: String { imageURL }
    public var imageURL: String
    /// 形如 `Figure 1`。取不到时回退为 `图 N`。
    public var label: String
    /// 不含 `Figure 1:` 前缀的图注正文。
    public var caption: String
    /// ⚠️ LaTeXML 写的是**排版显示尺寸**，不是图片的原始像素尺寸。
    ///
    /// 实测（`arxiv.org/html/2506.06962`，7 张图逐张下载核对）：真实像素宽是这里
    /// 的 3.0–10.3 倍，例如声明 `419×214` 的文件其实是 `1385×705`。
    /// **长宽比则完全一致**（7/7 误差 < 0.4%），所以这两个字段只应被用来算比例、
    /// 绝不能拿去当"原图分辨率"展示。
    public var width: Int?
    public var height: Int?

    // ---- 用于挑选“核心图”的信号（详见 KeyFigureSelector）----
    /// 正文里对这张图的引用次数。数量来源于 HTML 里 `class="ltx_ref"` 的链接，
    /// 其 `title` 属性形如 `Figure 1 ‣ 论文标题`。
    public var referenceCount: Int
    /// 是否位于附录 / 补充材料（锚点形如 `A3.F7`）。
    public var isAppendix: Bool

    /// 是不是矢量图（SVG）。
    ///
    /// 从地址推断而不是额外存字段：缓存里已有的记录因此无需迁移，
    /// 而且 `.svg` 这个事实本来就写在地址里，存两份只会不一致。
    ///
    /// UIKit 解不了 SVG，渲染前必须先栅格化 —— 见 App 侧的 `VectorRasterizer`。
    public var isVector: Bool {
        imageURL.lowercased().hasSuffix(".svg")
    }

    public init(imageURL: String, label: String, caption: String,
                width: Int? = nil, height: Int? = nil,
                referenceCount: Int = 0, isAppendix: Bool = false) {
        self.imageURL = imageURL
        self.label = label
        self.caption = caption
        self.width = width
        self.height = height
        self.referenceCount = referenceCount
        self.isAppendix = isAppendix
    }

    /// 宽容解码：新增字段缺省时回退到默认值，
    /// 免得旧版本的缓存文件整体解不出来、白白丢掉缓存。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imageURL = try container.decode(String.self, forKey: .imageURL)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? "图"
        caption = try container.decodeIfPresent(String.self, forKey: .caption) ?? ""
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        referenceCount = try container.decodeIfPresent(Int.self, forKey: .referenceCount) ?? 0
        isAppendix = try container.decodeIfPresent(Bool.self, forKey: .isAppendix) ?? false
    }

    /// 宽高比，用于在图片加载完成前占位，避免列表跳动。
    public var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }
}

/// 一篇论文的图表集合（会被缓存）。
public struct PaperFigureSet: Codable, Sendable, Hashable {
    public var arxivID: String
    /// 实际解析用的页面地址；取不到时为 nil。
    public var sourceURL: String?
    public var figures: [PaperFigure]
    /// 启发式选出的“核心图”。用户可在 App 里手动改选。
    public var keyFigureID: String?
    /// 作者机构名（去重、按出现顺序）。
    ///
    /// 为什么放在"图表"这个结构里：它和图表来自**同一次 HTML 抓取**、
    /// 同一个缓存条目。单独存一份就要么多存一个文件，要么再抓一次页面。
    /// 语义上这个结构其实是"arXiv HTML 页面的摘要"，`figures` 只是其中一部分。
    ///
    /// arXiv 的 Atom API **不返回**机构，所以这是最省的一次性来源：
    /// 既不用额外请求，又能覆盖 Semantic Scholar 还没有收录的新论文。
    public var institutions: [String]
    public var fetchedAt: Date
    /// 需要向用户解释的说明（没有 HTML 版、网络失败等）；正常取到图时为 nil。
    public var note: String?

    public init(arxivID: String, sourceURL: String? = nil,
                figures: [PaperFigure] = [], keyFigureID: String? = nil,
                institutions: [String] = [],
                fetchedAt: Date = Date(), note: String? = nil) {
        self.arxivID = arxivID
        self.sourceURL = sourceURL
        self.figures = figures
        self.fetchedAt = fetchedAt
        self.note = note
        self.keyFigureID = keyFigureID
        self.institutions = institutions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        arxivID = try container.decode(String.self, forKey: .arxivID)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        figures = try container.decodeIfPresent([PaperFigure].self, forKey: .figures) ?? []
        keyFigureID = try container.decodeIfPresent(String.self, forKey: .keyFigureID)
        institutions = try container.decodeIfPresent([String].self,
                                                     forKey: .institutions) ?? []
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? Date()
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    /// 核心图（自动选出；列表为空时返回 nil）。
    ///
    /// **每次都重新计算**，而不是直接用落盘的 `keyFigureID`。
    /// 理由是：选择逻辑是纯函数、开销可忽略，而缓存里那份是**抓取当时**的选择。
    /// 一旦调整权重（这个打分函数在本项目里改过几轮），旧缓存会一直显示过时的
    /// 结果，除非用户手动清缓存 —— 而重算让调参完全不需要重下页面。
    /// `keyFigureID` 仍然落盘，但只作为"当时选了什么"的记录，便于排查。
    public var keyFigure: PaperFigure? {
        KeyFigureSelector.select(from: figures) ?? figures.first
    }

    /// 除核心图之外的其余图，用于详情页底部列表。
    public var otherFigures: [PaperFigure] {
        guard let key = keyFigure else { return figures }
        return figures.filter { $0.imageURL != key.imageURL }
    }
}

// MARK: - 核心图选取

/// 从论文的全部插图中挑出最值得放在显眼位置的那一张。
///
/// 为什么是启发式而不是让大模型判断
/// --------------------------------
/// 这个判断可以用**页面里已有的结构信号**做得相当准，而且完全确定、可解释、
/// 零额外网络与费用：
///
/// 1. **图注关键词**（最强）
///      论文自己在图注里写了 "Overview of …" / "architecture" / "proposed" 的时候，
///      这几乎就是作者在告诉我们哪张图最重要 —— 比任何统计信号都准。
///
///   2. **是不是第一张图**
///      论文的惯例就是拿 Figure 1 当图形摘要。
///
///   3. **出现位置**
///      越靠前越可能是总览（引言里的图比实验节的图更可能是门面）。
///
///   4. **正文引用次数**（最弱，且刻意压低）
///      直觉上"被引最多的图最重要"，**实测恰恰相反**：
///      `2306.00978`（AWQ）的 Figure 1 是方法总览图，正文里对 `#S1.F1` 的引用
///      **一次都没有** —— 因为图形摘要本来就是让人看的，没人会在正文写"见图 1"。
///      真正被反复引用的是消融和结果图。
///
///      这一条是**踩过坑改过来的**：早期版本给引用次数 2.0 的权重，导致
///      16 篇抽样里有 3 篇把消融图当成了核心图（AWQ 选中 Figure 8 而非 Figure 1）。
///      现在权重降到 0.9，并且取对数压缩。
///
///   5. **附录降权**
///      补充材料里的图不该当门面；见下方注释。
///
/// 实例核对（真实页面）：
///   * `2506.06962` Figure 1（首图 + "Comparison" 总览对比图）✓
///   * `2608.10703` Figure 2（"Overview of our situated B-data framework"，
///     不是首图但被关键词选中 —— 这正是关键词比"位置"更准的例子）✓
///   * `2306.00978` Figure 1（首图加成纠正了引用次数为 0 的误导）✓
///
/// 用户如果不认同，可以在 App 里手动改选。
public enum KeyFigureSelector {

    /// 图注里出现这些词，说明更可能是总览 / 架构图。
    ///
    /// 刻意**不含** "comparison"：它同样是结果图的高频词，
    /// 放进来的话会把消融对比图顶上来 —— 而这正是我们要避免的失败模式。
    static let overviewKeywords: [String] = [
        "overview", "architecture", "framework", "pipeline", "illustration",
        "our method", "proposed", "teaser", "workflow", "schematic",
        "concept", "paradigm",
    ]

    /// 关键词只在图注**开头**这么多字符内才算数。
    ///
    /// 起因是 `2306.00978`（AWQ）的 Figure 8：它的图注在第 184 个字符处出现
    /// "Our method is more robust to the calibration set distribution" ——
    /// 这是消融图在**对比**时提到本文方法，却让它在旧评分里反超了总览图。
    ///
    /// 真实的规律是：总览图的图注**开头**就在说明"这张图画的是什么"
    /// （"Overview of …"、"Illustration of our method …"、"Overall architecture …"），
    /// 而结果图的图注要到后半段做对比时才会提到本文方法。
    static let captionKeywordWindow = 80

    /// 图注开头出现这些词，说明是实验 / 消融类图，不该当门面。
    ///
    /// 这类图注的用词和总览图很像，光靠正向词区分不开。真实例子
    /// （`2507.22171`）：消融图的图注是
    /// "Ablation study of crossover and mutation operations in our proposed pipeline."
    /// —— "proposed" 和 "pipeline" 双双命中正向词，于是反超了真正的
    /// Figure 2 "The proposed framework."。靠 "ablation" 这个负向词才能拉开。
    static let resultsKeywords: [String] = [
        "ablation", "hyperparameter", "sensitivity", "results", "benchmark",
        "throughput", "latency", "loss curve", "training curve", "quantitative",
    ]

    public static func select(from figures: [PaperFigure]) -> PaperFigure? {
        select(from: figures, excluding: [])
    }

    /// 同上，但可以排除一批地址（已确认下载不到的坏图）。
    ///
    /// 为什么要排除：arXiv 偶尔会生成指向不存在文件的图片路径
    /// （实测 `2404.07677` 的 `latex/figs/` 子目录根本没被发布，图片 404）。
    /// 此时应该退而选下一张，而不是留一个永远的空框。
    ///
    /// 位置加成用**原数组**的下标，不用过滤后的下标 —— 否则排除一张图
    /// 会让后面所有图的位置分整体上移，选择结果变得难以预测。
    public static func select(from figures: [PaperFigure],
                             excluding broken: Set<String>) -> PaperFigure? {
        var best: (figure: PaperFigure, score: Double)?
        for (index, figure) in figures.enumerated() where !broken.contains(figure.imageURL) {
            let value = score(figure, index: index, total: figures.count)
            if best == nil || value > best!.score {
                best = (figure, value)
            }
        }
        // 全部都是坏图时退回第一张（宁可显示加载失败，也不要什么都不显示）
        return best?.figure ?? figures.first
    }

    /// 单张图的得分。分开暴露出来便于单测与调参。
    public static func score(_ figure: PaperFigure, index: Int, total: Int) -> Double {
        var score = 0.0

        // 1) 图注关键词（只看开头，见 captionKeywordWindow）
        let prefix = String(figure.caption.lowercased().prefix(captionKeywordWindow))
        let hits = overviewKeywords.filter { prefix.contains($0) }.count
        score += 2.2 * min(1.0, Double(hits) / 2.0)

        // 1b) 实验 / 消融类图减分
        if resultsKeywords.contains(where: { prefix.contains($0) }) {
            score -= 1.6
        }

        // 2) 首图加成
        if index == 0 { score += 1.8 }

        // 3) 位置越靠前越可能是总览
        if total > 1 {
            score += 0.5 * (1.0 - Double(index) / Double(total - 1))
        }

        // 4) 引用次数（对数压缩，权重刻意压得比直觉低 —— 见类型文档）
        score += 0.9 * log1p(Double(figure.referenceCount))

        // 5) 附录 / 补充材料降权
        //
        // 用**乘性**而不是固定减分：附录图哪怕被引 20 次，也不该当论文门面；
        // 固定减分压不住高引用量（实测 20 次引用的附录图仍会胜出）。
        // 乘性还有个好处：对"整篇论文的图都在补充材料里"的情况，
        // 所有候选同比例缩放，仍能选出其中相对最好的那张。
        if figure.isAppendix { score *= 0.35 }

        return score
    }
}

// MARK: - HTML 解析

public enum ArxivHTMLFigureParser {

    /// 单篇最多保留多少张图。论文动辄十几张，全列出来既拖慢也不实用。
    public static let maxFigures = 24

    /// 单篇最多保留多少个机构。
    public static let maxInstitutions = 6

    /// 小于这个尺寸的图片视为装饰性元素丢弃。
    private static let minimumDimension = 100

    // MARK: 作者机构

    /// 作者块里那些"不是机构"的说明文字。
    ///
    /// LaTeXML 把作者块里的各种 `\thanks` 注释都标成 `ltx_role_affiliation`，
    /// 实测 `2609.11877` 里就混进了 "These authors contributed equally"。
    /// 这类文本若当成机构，会白白给论文加一个机构维度分。
    private static let affiliationNoiseMarkers: [String] = [
        "contributed equally", "equal contribution", "corresponding author",
        "correspondence", "work done while", "work was done",
        "authors are listed", "author ordering", "joint first author",
        "now with", "currently at", "intern at",
    ]

    /// 从 arXiv HTML 的作者块里提取机构名。
    ///
    /// 真实结构（`arxiv.org/html/2606.05868`）：
    /// ```html
    /// <span class="ltx_contact ltx_role_affiliation">
    ///   <span class="ltx_contact_name">Affiliation: </span>Postal Savings Bank of China, Beijing, China
    /// </span>
    /// ```
    /// 注意 `ltx_contact_name` 里那个 "Affiliation: " 只是标签，要剥掉；
    /// 而它在不同页面里可能是 "Email: " 之类，所以统一按"标签 + 内容"处理。
    public static func affiliations(in html: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        let pattern = #"<span[^>]*class="[^"]*ltx_role_affiliation[^"]*"[^>]*>"#
        for match in matches(pattern, in: html) {
            guard let openTag = Range(match.range, in: html),
                  let inner = matchingSpanContent(in: html, after: openTag.upperBound)
            else { continue }

            // 先把上标换成分隔符，再剥标签 —— 顺序很重要，见 replacingSuperscripts
            let sanitized = replacingSuperscriptsWithSeparator(inner)
            let text = decodeEntities(stripTags(sanitized))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // 有的论文把**全部机构**塞进同一个 affiliation 块，用分号分隔，
            // 并给每家加一个上标序号：
            //   "<sup>1</sup>Hunyuan Speech Team, Tencent; <sup>2</sup>Zhejiang University; …"
            // 不拆开的话，列表里会显示成一长串，而"取最好的一档"也只能看到第一家。
            for part in splitAffiliationEntries(text) {
                guard let cleaned = normalizeAffiliation(part) else { continue }
                let key = cleaned.lowercased()
                guard seen.insert(key).inserted else { continue }
                result.append(cleaned)
                if result.count >= maxInstitutions { return result }
            }
        }
        return result
    }

    /// 把 `<sup>1</sup>` 这类上标替换成分号。
    ///
    /// 为什么不直接在剥完标签的文本上"剥前导数字"：真实页面里序号是
    /// `<sup id="id1" class="ltx_sup">1</sup>`，剥标签后与机构名粘连成
    /// `1Hunyuan Speech Team`；而纯文本剥数字会误伤 `3M Company` 这种真名
    /// （实测被削成 `M Company`）。按元素精确替换就没有这个歧义。
    static func replacingSuperscriptsWithSeparator(_ html: String) -> String {
        let found = matches(#"(?s)<sup\b[^>]*>.*?</sup>"#, in: html)
        guard !found.isEmpty else { return html }

        var result = ""
        var cursor = html.startIndex
        for match in found {
            guard let range = Range(match.range, in: html) else { continue }
            result += html[cursor..<range.lowerBound]
            result += ";"
            cursor = range.upperBound
        }
        result += html[cursor...]
        return result
    }

    /// 按分号把一条 affiliation 拆成多条，并剥掉可能残留的序号标记。
    static func splitAffiliationEntries(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ";；")
        return text.components(separatedBy: separators).compactMap { raw in
            let part = strippingLeadingIndex(
                raw.trimmingCharacters(in: .whitespacesAndNewlines))
            return part.isEmpty ? nil : part
        }
    }

    /// 剥掉开头的序号标记，如 `1Hunyuan` 里的 `1`、`*Stanford` 里的 `*`。
    ///
    /// ⚠️ 要求标记后面跟着**至少两个字母**：否则 `3M Company` 会被削成 `M Company`
    /// （这个 bug 真实发生过，由单测抓出来）。
    static func strippingLeadingIndex(_ text: String) -> String {
        let markers = text.prefix { $0.isNumber || "*†‡§¶".contains($0) }
        guard !markers.isEmpty else { return text }

        let rest = text.dropFirst(markers.count)
        let letters = rest.prefix { $0.isLetter }
        guard letters.count >= 2 else { return text }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 机构名里常见的"后缀词"。用来把"人名"和"机构名"区分开。
    private static let institutionSuffixes: [String] = [
        "university", "univ", "institute", "institution", "college", "school",
        "academy", "laboratory", "lab", "labs", "research", "center", "centre",
        "inc", "corp", "corporation", "ltd", "limited", "gmbh", "technologies",
        "technology", "group", "foundation", "hospital", "ai", "deepmind",
        "department", "faculty", "division", "school of",
    ]

    /// 判断一条"机构"其实是**人名**。
    ///
    /// 真实案例：`arxiv.org/html/2609.11877` 里 LaTeXML 把作者 "Namkyeong Lee"
    /// 也标成了 `ltx_role_affiliation`。它会被当成机构显示出来，非常突兀。
    ///
    /// 判定规则：**多词 + 没有逗号 + 没有任何机构后缀词**。真实机构要么带逗号
    /// （"Huawei Technologies, Shenzhen, China"），要么带后缀（"Tsinghua University"），
    /// 所以这条规则很少误伤。单词条目一律不判（"Meta"、"DeepMind" 都是合法机构）。
    static func looksLikePersonName(_ text: String) -> Bool {
        guard !text.contains(","), !text.contains("&") else { return false }
        let words = PyCompat.splitWhitespace(text)
        guard (2...4).contains(words.count) else { return false }
        let lowered = text.lowercased()
        return !institutionSuffixes.contains { lowered.contains($0) }
    }

    /// 清洗一条机构文本；不像机构就返回 nil。
    static func normalizeAffiliation(_ raw: String) -> String? {
        var text = raw
        // 剥掉 "Affiliation: " / "Email: " 之类的标签
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex,
                                                               to: colon) <= 20 {
            let prefix = text[text.startIndex..<colon].lowercased()
            let knownLabels = ["affiliation", "email", "e-mail", "institution", "department"]
            if knownLabels.contains(where: { prefix.contains($0) }) {
                text = String(text[text.index(after: colon)...])
            }
        }
        text = PyCompat.collapseWhitespace(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lowered = text.lowercased()
        guard text.count >= 3, text.count <= 160 else { return nil }
        // 邮箱、网址不是机构
        guard !text.contains("@"), !lowered.contains("http"), !lowered.contains("www.") else {
            return nil
        }
        // "These authors contributed equally" 这类说明不是机构
        guard !affiliationNoiseMarkers.contains(where: { lowered.contains($0) }) else {
            return nil
        }
        // 被误标成机构的人名
        guard !looksLikePersonName(text) else { return nil }
        // 以逗号或句号结尾时去掉尾部标点
        while let last = text.last, ".,;".contains(last) {
            text.removeLast()
        }
        return text.isEmpty ? nil : text
    }

    /// 从 `openTag` 之后开始，按 `<span>` 配平找到对应的 `</span>`，返回其间的内容。
    ///
    /// 为什么不能简单地取到"第一个 `</span>`"：机构那一层里面还嵌着一个
    /// `ltx_contact_name` 的 span，直接截断会把内容切掉一半。
    ///
    /// ⚠️ 后面**再也找不到 `<span` 开标签**时不能直接失败 ——
    /// 那正是最后一个机构所处的位置（文档剩下的部分只有 `</span>`）。
    /// 早期版本在这里 `guard let open` 直接返回 nil，结果每次都丢掉最后一个机构。
    static func matchingSpanContent(in html: String, after start: String.Index) -> String? {
        var index = start
        var depth = 1

        while depth > 0 {
            guard let close = html.range(of: "</span>", range: index..<html.endIndex)
            else { return nil }

            let open = html.range(of: "<span", range: index..<html.endIndex)
            if let open, open.lowerBound < close.lowerBound {
                depth += 1
                index = open.upperBound
            } else {
                depth -= 1
                if depth == 0 { return String(html[start..<close.lowerBound]) }
                index = close.upperBound
            }
        }
        return nil
    }

    public static func parse(html: String, arxivID: String,
                             pageURL: String) -> [PaperFigure] {
        // 先统计正文对每张图的引用次数 —— 这是挑选核心图最重要的信号
        let references = referenceCounts(in: html)

        var figures: [PaperFigure] = []
        var seen = Set<String>()
        var unnumberedCount = 0

        for block in matches(#"(?s)<figure\b([^>]*)>(.*?)</figure>"#, in: html) {
            guard figures.count < maxFigures else { break }
            guard let attributes = substring(html, block.range(at: 1)),
                  let inner = substring(html, block.range(at: 2)) else { continue }

            // LaTeXML 用 ltx_figure 标记真正的插图；算法、表格用 ltx_float。
            // 这里以 ltx_figure 为准，同时接受含 ltx_graphics 的块作为兜底。
            let lowered = attributes.lowercased()
            guard lowered.contains("ltx_figure") || inner.contains("ltx_graphics") else {
                continue
            }

            guard let imageAttributes = imageTagAttributes(in: inner),
                  let source = graphicSource(in: imageAttributes),
                  let imageURL = absoluteURL(source, pageURL: pageURL),
                  seen.insert(imageURL).inserted
            else { continue }

            let width = attribute("width", in: imageAttributes).flatMap(Int.init)
            let height = attribute("height", in: imageAttributes).flatMap(Int.init)

            // 丢掉图标一类的装饰图
            if let width, let height,
               width < minimumDimension, height < minimumDimension { continue }

            let captionHTML = firstMatch(#"(?s)<figcaption\b[^>]*>(.*?)</figcaption>"#, in: inner)
                .flatMap { substring(inner, $0.range(at: 1)) } ?? ""
            let captionText = decodeEntities(stripTags(captionHTML))
            var (label, caption) = splitLabel(captionText)

            let anchor = attribute("id", in: attributes) ?? ""

            // 多子图面板（"Figure 5" 由 (a)(b) 两个面板组成）的图注是
            // "(b) 训练曲线" 这种形式，自身没有 "Figure 5:" 前缀。
            // 必须在「未编号」兜底之前判定，否则会被当成无图注的图。
            if let panel = panelLabel(anchor: anchor, caption: caption) {
                label = panel
            } else if label == Self.unnumberedLabel {
                unnumberedCount += 1
                label = "\(Self.unnumberedLabel) \(unnumberedCount)"
            }

            let appendix = isAppendixAnchor(anchor)
                || label.lowercased().hasPrefix("supplement")

            figures.append(PaperFigure(
                imageURL: imageURL,
                label: label,
                caption: caption,
                width: width,
                height: height,
                referenceCount: referenceCount(for: anchor, in: references),
                isAppendix: appendix))
        }

        return figures
    }

    // MARK: 引用次数

    /// 统计正文对每张图的引用次数，键为 figure 的锚点 id。
    ///
    /// 关键在于**图号写在 `title` 属性里**：链接的可见文字只有一个数字，
    /// 形如
    /// `<a href="#S0.F1" title="Figure 1 ‣ 论文标题" class="ltx_ref"><span>1</span></a>`。
    /// 只看文字会完全统计不到（这一点是靠真实页面核对出来的）。
    static func referenceCounts(in html: String) -> [String: Int] {
        var counts: [String: Int] = [:]

        for match in matches(#"(?s)<a\b([^>]*)>"#, in: html) {
            guard let attributes = substring(html, match.range(at: 1)),
                  let cssClass = attribute("class", in: attributes),
                  cssClass.contains("ltx_ref"),                      // 只认交叉引用
                  let href = attribute("href", in: attributes),
                  href.hasPrefix("#"),
                  let title = attribute("title", in: attributes),
                  isFigureReference(title)                           // 排除章节 / 表格 / 算法引用
            else { continue }

            counts[String(href.dropFirst()), default: 0] += 1
        }
        return counts
    }

    /// 引用的 `title` 是否形如 `Figure 1 ‣ …`。
    static func isFigureReference(_ title: String) -> Bool {
        let lowered = title.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("figure ") || lowered.hasPrefix("fig. ")
            || lowered.hasPrefix("fig ")
    }

    /// 汇总某张图（含其子图 `S0.F1.g2`）的引用次数。
    ///
    /// 用 `id + "."` 做前缀匹配而不是裸 `hasPrefix`，
    /// 否则 `S0.F10` 会被错误地算进 `S0.F1`。
    static func referenceCount(for anchor: String, in counts: [String: Int]) -> Int {
        guard !anchor.isEmpty else { return 0 }
        return counts.reduce(0) { total, entry in
            let key = entry.key
            guard key == anchor || key.hasPrefix(anchor + ".") else { return total }
            return total + entry.value
        }
    }

    /// 附录锚点形如 `A3.F7`，正文锚点形如 `S3.F2`。
    static func isAppendixAnchor(_ id: String) -> Bool {
        guard let first = id.first, first == "A" || first == "a" else { return false }
        return id.dropFirst().first?.isNumber == true
    }

    // MARK: 标签处理

    /// 取第一个图形标签的属性串。
    ///
    /// LaTeXML 对**位图**输出 `<img src="….png">`，
    /// 对**矢量图**输出 `<object type="image/svg+xml" data="….svg">`（地址在 `data` 上）。
    ///
    /// 抽样 6 篇论文共 46 张图，两者**各占一半**（img 23 / object 23）。
    /// 只认 `<img>` 会丢掉一半的图，而且丢掉的往往是 Figure 1 这种总览图 ——
    /// 例如 `2402.12317` 只有 1 张是 `<img>`，其余 5 张全是 `<object>`。
    private static func imageTagAttributes(in html: String) -> String? {
        for tag in ["img", "object", "embed", "source"] {
            if let match = firstMatch(#"(?s)<\#(tag)\b([^>]*)>"#, in: html) {
                return substring(html, match.range(at: 1))
            }
        }
        return nil
    }

    /// 从图形标签属性里取出图片地址。
    /// `<object>` 把地址放在 `data` 而不是 `src` 上，必须一并支持。
    private static func graphicSource(in attributes: String) -> String? {
        attribute("src", in: attributes)
            ?? attribute("data-src", in: attributes)
            ?? attribute("data", in: attributes)
            ?? firstSrcsetURL(in: attributes)
    }

    private static func firstSrcsetURL(in attributes: String) -> String? {
        guard let srcset = attribute("srcset", in: attributes) else { return nil }
        // srcset 形如 "a.png 1x, b.png 2x"，取第一个
        return srcset.split(separator: ",").first?
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first
            .map(String.init)
    }

    /// 读取标签属性，兼容单引号、双引号与无引号三种写法。
    private static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let match = firstMatch(pattern, in: attributes) else { return nil }
        for group in 1...3 {
            if let value = substring(attributes, match.range(at: group)) {
                return value
            }
        }
        return nil
    }

    /// 把相对路径拼成绝对地址。
    ///
    /// 图片 src 形如 `2506.06962v3/idea2.png`，**带了版本号**，
    /// 不能直接相对请求用的无版本 URL 解析，否则会拼出
    /// `/html/2506.06962/2506.06962v3/idea2.png` 这种坏地址。
    /// 统一以 `/html/` 为基准拼接即可。
    static func absoluteURL(_ source: String, pageURL: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // data: / mailto: 之类一律不要
        guard !trimmed.lowercased().hasPrefix("data:") else { return nil }

        if trimmed.lowercased().hasPrefix("http") {
            // 协议相对地址
            return trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("/") { return "https://arxiv.org" + trimmed }
        return "https://arxiv.org/html/" + trimmed
    }

    /// 去掉标签、解码实体、折叠空白。
    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"(?s)<[^>]*>"#, with: "",
                                  options: .regularExpression)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // 数字实体：&#8212; / &#x2014;
        if result.contains("&#") {
            result = replaceNumericEntities(in: result)
        }
        return result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static let namedEntities: [(String, String)] = [
        ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
        ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
        ("&ndash;", "–"), ("&mdash;", "—"), ("&hellip;", "…"),
        ("&times;", "×"), ("&plusmn;", "±"), ("&le;", "≤"), ("&ge;", "≥"),
        ("&laquo;", "«"), ("&raquo;", "»"), ("&deg;", "°"), ("&mu;", "µ"),
    ]

    private static func replaceNumericEntities(in text: String) -> String {
        let pattern = "&#(x?)([0-9A-Fa-f]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let full = Range(match.range, in: text),
                  let flagRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            let isHex = !text[flagRange].isEmpty
            let digits = String(text[valueRange])
            let value = UInt32(digits, radix: isHex ? 16 : 10)

            result += text[cursor..<full.lowerBound]
            if let value, let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
            } else {
                result += text[full]
            }
            cursor = full.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// 从锚点里取出图号：`S0.F1` / `S3.F5.sf2` / `A3.F7` 都返回对应数字。
    ///
    /// 子图锚点（`S3.F5.sf2`）要能取到父图号 5，因此**不能**把 `F(\d+)` 锚定到串尾。
    static func figureNumber(from anchor: String) -> Int? {
        guard let match = firstMatch(#"F(\d+)"#, in: anchor),
              let digits = substring(anchor, match.range(at: 1)) else { return nil }
        return Int(digits)
    }

    /// 多子图面板的图号：`Figure 5 (a)` 形式；不是面板则返回 nil。
    ///
    /// 真实页面（`arxiv.org/html/2606.05868`）里 Figure 5 被 LaTeXML 拆成
    /// `S3.F5.sf1` / `S3.F5.sf2` 两个块，图注分别是 `(a) …` 和 `(b) …`。
    static func panelLabel(anchor: String, caption: String) -> String? {
        guard let match = firstMatch(#"^\s*\(([a-zA-Z])\)"#, in: caption),
              let letter = substring(caption, match.range(at: 1)),
              let number = figureNumber(from: anchor) else { return nil }
        return "Figure \(number) (\(letter))"
    }

    /// 图注里没有图号时的占位标签；解析阶段会把它替换成“未编号插图 N”。
    ///
    /// ⚠️ 这里**不能**用「图 N」这种按出现顺序编号的写法。
    /// 真实页面 `arxiv.org/html/2609.11877` 的正文里有图无图注
    /// （`S2.SS4.fig1`、`S2.SS7.fig1`），按顺序编出来就是“图 2 / 图 3”，
    /// 而这篇论文根本没有 Figure 2 / Figure 3 —— 用户会以为图号就是正文里的图号。
    static let unnumberedLabel = "未编号插图"

    /// 把 `Figure 1: 正文…` 拆成标签与正文。
    static func splitLabel(_ text: String) -> (String, String) {
        // ⚠️ 这里用 Swift 的原始字符串 `#"..."#`，它**不会**解析 `\u{2014}` 这类转义，
        // 写进去会被当成字面量传给 NSRegularExpression，导致正则编译失败、
        // 表现为“编号永远匹配不上”。所以破折号直接写成字面字符。
        //
        // 限定词（Supplementary / Appendix / Extended Data）是可选的且必须支持：
        // 真实页面上确实存在 `Supplementary Figure 4: …` 这种写法。
        let pattern = #"^\s*(?:(Supplementary|Supplemental|Supp\.?|Appendix|Extended Data)\s+)?(Figure|Fig\.?|Table|Algorithm)\s*([0-9]+[A-Za-z]?)\s*[:.—–\-]?\s*"#
        guard let match = firstMatch(pattern, in: text, caseInsensitive: true),
              let full = Range(match.range, in: text) else {
            return (unnumberedLabel, text.trimmingCharacters(in: .whitespaces))
        }

        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }

        let kind = group(2) ?? "Figure"
        let number = group(3) ?? ""
        let normalizedKind = kind.lowercased().hasPrefix("fig") ? "Figure"
            : kind.prefix(1).uppercased() + kind.dropFirst().lowercased()

        var parts: [String] = []
        if let qualifier = group(1) {
            let lowered = qualifier.lowercased()
            parts.append(lowered.hasPrefix("supp") ? "Supplementary"
                         : qualifier.prefix(1).uppercased() + qualifier.dropFirst().lowercased())
        }
        parts.append(normalizedKind)
        parts.append(number)
        let label = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        let caption = String(text[full.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        return (label, caption.isEmpty ? text : caption)
    }

    // MARK: 正则工具

    private static func matches(_ pattern: String, in text: String,
                                caseInsensitive: Bool = false) -> [NSTextCheckingResult] {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            // 正则写错时必须显形：静默返回空数组会表现为“页面里没有图”，
            // 极难定位（本项目就真的踩过一次：原始字符串里的 \u{2014} 让正则编译失败）。
            assertionFailure("图表解析用的正则无法编译：\(pattern)")
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func firstMatch(_ pattern: String, in text: String,
                                   caseInsensitive: Bool = false) -> NSTextCheckingResult? {
        matches(pattern, in: text, caseInsensitive: caseInsensitive).first
    }

    private static func substring(_ text: String, _ range: NSRange) -> String? {
        guard let range = Range(range, in: text) else { return nil }
        return String(text[range])
    }
}

// MARK: - 抓取

public actor FigureExtractor {

    public static let baseURL = "https://arxiv.org/html/"

    private let timeout: TimeInterval
    private let userAgent: String
    private let session: URLSession

    /// 两次请求之间的最小间隔。列表批量预取核心图时会连续抓取几十个页面，
    /// 必须有节流，否则对 arXiv 是明显的滥用。（列表串行预取时基本感知不到。）
    private let minInterval: TimeInterval
    private var lastRequestAt: Date?

    public init(timeout: TimeInterval = 20,
                userAgent: String = "new-paper-scraper/1.0 (iOS)",
                minInterval: TimeInterval = 1.5) {
        self.timeout = timeout
        self.userAgent = userAgent
        self.minInterval = minInterval

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    /// 节流：与上一次请求至少间隔 `minInterval`。
    private func throttle() async {
        guard let last = lastRequestAt else { return }
        let elapsed = Date().timeIntervalSince(last)
        let remaining = minInterval - elapsed
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }

    /// 从论文 URL 中取出 arXiv ID（`.../abs/2506.06962` -> `2506.06962`）。
    public static func arxivID(from url: String) -> String? {
        guard let range = url.range(of: "arxiv.org/abs/", options: .caseInsensitive) else {
            return nil
        }
        var rest = String(url[range.upperBound...])
        if let cut = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = String(rest[..<cut])
        }
        return rest.isEmpty ? nil : rest
    }

    /// 抓取并解析图表。失败不抛错，而是把原因放进 `note`，便于 UI 直接展示。
    public func fetch(arxivID: String) async -> PaperFigureSet {
        guard let url = URL(string: Self.baseURL + arxivID) else {
            return PaperFigureSet(arxivID: arxivID, note: "论文编号无效")
        }

        await throttle()
        lastRequestAt = Date()

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return PaperFigureSet(arxivID: arxivID, note: "响应异常")
            }
            guard http.statusCode == 200 else {
                return PaperFigureSet(
                    arxivID: arxivID,
                    note: http.statusCode == 404
                        ? "这篇论文还没有 arXiv 生成的 HTML 版本，无法提取图表"
                        : "arXiv 返回 HTTP \(http.statusCode)")
            }
            guard let html = String(data: data, encoding: .utf8) else {
                return PaperFigureSet(arxivID: arxivID, note: "页面编码无法识别")
            }

            let figures = ArxivHTMLFigureParser.parse(
                html: html, arxivID: arxivID, pageURL: url.absoluteString)
            let institutions = ArxivHTMLFigureParser.affiliations(in: html)

            return PaperFigureSet(
                arxivID: arxivID,
                sourceURL: url.absoluteString,
                figures: figures,
                keyFigureID: KeyFigureSelector.select(from: figures)?.imageURL,
                institutions: institutions,
                note: figures.isEmpty ? "这篇论文的 HTML 版本里没有插图" : nil)
        } catch {
            let message = (error as? URLError)?.code == .timedOut
                ? "获取图表超时" : "获取图表失败：\(error.localizedDescription)"
            return PaperFigureSet(arxivID: arxivID, note: message)
        }
    }
}
