//
//  FigureExtractorTests.swift
//  PaperScraperCoreTests
//
//  图表提取的回归测试。测试夹具取自**真实抓取的 arXiv HTML**，
//  结构（类名、属性顺序、内联 span）都保持原样 —— 正则解析这类代码，
//  只有拿真实样本才能测出问题。
//

import XCTest
@testable import PaperScraperCore

final class FigureExtractorTests: XCTestCase {

    /// 取自 https://arxiv.org/html/2506.06962 的真实片段
    private let realFigure = """
    <figure id="S0.F1" class="ltx_figure"><img src="2506.06962v3/idea2.png" \
    id="S0.F1.g1" class="ltx_graphics ltx_centering ltx_img_landscape" \
    style="aspect-ratio:419/214;" width="419" height="214" alt="Refer to caption"> \
    <figcaption class="ltx_caption ltx_centering"><span class="ltx_tag ltx_tag_figure">\
    Figure 1: </span>Comparison between Autoregressive Retrieval Augmentation (\
    <span id="S0.F1.8" class="ltx_text ltx_font_smallcaps">AR-RAG</span>) for image \
    generation in (c) and existing image generation paradigms in (a)&nbsp;(b).</figcaption> </figure>
    """

    /// 真实片段：算法块也用了 <figure>，但没有插图，必须被跳过
    private let realAlgorithm = """
    <figure id="alg1" class="ltx_float ltx_float_algorithm ltx_framed ltx_framed_top"> \
    <figcaption class="ltx_caption"><span class="ltx_tag ltx_tag_float"><span \
    id="alg1.4" class="ltx_text ltx_font_bold">Algorithm 1</span> </span> <span \
    id="alg1.5" class="ltx_text ltx_font_smallcaps">EvoR</span> Pipeline</figcaption> \
    <div id="alg1.6" class="ltx_listing ltx_framed"> <div id="alg1.l1" \
    class="ltx_listingline"> <span class="ltx_tag ltx_tag_listingline">1:</span> \
    <span id="alg1.l1.2" class="ltx_text ltx_font_bold">Input:</span> \
    <math id="alg1.l1.m1" alttext="n"><semantics><mi>n</mi></semantics></math> \
    </div> </div> </figure>
    """

    private func parse(_ html: String) -> [PaperFigure] {
        ArxivHTMLFigureParser.parse(html: html, arxivID: "2506.06962",
                                   pageURL: "https://arxiv.org/html/2506.06962")
    }

    // MARK: 主流程

    func testParsesRealFigure() throws {
        let figures = parse(realFigure)
        XCTAssertEqual(figures.count, 1)

        let figure = try XCTUnwrap(figures.first)
        XCTAssertEqual(figure.label, "Figure 1")
        XCTAssertEqual(figure.imageURL, "https://arxiv.org/html/2506.06962v3/idea2.png")
        XCTAssertEqual(figure.width, 419)
        XCTAssertEqual(figure.height, 214)
        // 内联 span 被剥离、实体被解码、空白被折叠
        XCTAssertEqual(figure.caption,
                       "Comparison between Autoregressive Retrieval Augmentation "
                       + "(AR-RAG) for image generation in (c) and existing image "
                       + "generation paradigms in (a) (b).")
        XCTAssertEqual(figure.aspectRatio ?? 0, 419.0 / 214.0, accuracy: 1e-9)
    }

    func testSkipsAlgorithmAndTableFloats() {
        // 单个算法块 -> 0 张图
        XCTAssertTrue(parse(realAlgorithm).isEmpty)
        // 混在一起时只保留真正的插图
        let mixed = realAlgorithm + "\n" + realFigure + "\n" + realAlgorithm
        XCTAssertEqual(parse(mixed).count, 1)
    }

    func testHandlesMultipleFigures() throws {
        let html = realFigure.replacingOccurrences(of: "Figure 1:", with: "Figure 1:")
            + realFigure
                .replacingOccurrences(of: "S0.F1", with: "S3.F2")
                .replacingOccurrences(of: "idea2.png", with: "overview.png")
                .replacingOccurrences(of: "Figure 1:", with: "Figure 2:")

        let figures = parse(html)
        XCTAssertEqual(figures.count, 2)
        XCTAssertEqual(figures.map(\.label), ["Figure 1", "Figure 2"])
        XCTAssertEqual(figures[1].imageURL,
                       "https://arxiv.org/html/2506.06962v3/overview.png")
    }

    // MARK: 边界

    func testSkipsDecorativeImages() {
        // 宽高都小于阈值 -> 当作图标丢弃
        let html = """
        <figure class="ltx_figure"><img src="2506.06962v3/logo.png" width="32" height="32">\
        <figcaption>Figure 9: tiny</figcaption></figure>
        """
        XCTAssertTrue(parse(html).isEmpty)
    }

    func testKeepsWideButShortImages() {
        // 只要有一个维度够大就保留（有的流程图又扁又长）
        let html = """
        <figure class="ltx_figure"><img src="2506.06962v3/wide.png" width="900" height="60">\
        <figcaption>Figure 3: A wide pipeline.</figcaption></figure>
        """
        XCTAssertEqual(parse(html).count, 1)
    }

    func testHandlesMissingCaption() throws {
        let html = """
        <figure class="ltx_figure"><img src="2506.06962v3/nocap.png" width="400" height="300"></figure>
        """
        let figure = try XCTUnwrap(parse(html).first)
        XCTAssertEqual(figure.label, "未编号插图 1")
        XCTAssertEqual(figure.caption, "")
    }

    func testHandlesSingleQuotedAttributesAndAttributeOrder() throws {
        let html = """
        <figure class='ltx_figure'><img width='500' height='300' \
        class='ltx_graphics' src='2506.06962v3/quoted.png'><figcaption \
        class='ltx_caption'>Figure 4: Single quotes work.</figcaption></figure>
        """
        let figure = try XCTUnwrap(parse(html).first)
        XCTAssertEqual(figure.imageURL, "https://arxiv.org/html/2506.06962v3/quoted.png")
        XCTAssertEqual(figure.width, 500)
        XCTAssertEqual(figure.caption, "Single quotes work.")
    }

    func testFallsBackToSrcset() throws {
        let html = """
        <figure class="ltx_figure"><picture>\
        <source srcset="2506.06962v3/pic.webp 1x, 2506.06962v3/pic2x.webp 2x">\
        </picture><figcaption>Figure 5: srcset.</figcaption></figure>
        """
        let figure = try XCTUnwrap(parse(html).first)
        XCTAssertEqual(figure.imageURL, "https://arxiv.org/html/2506.06962v3/pic.webp")
    }

    func testDeduplicatesIdenticalImages() {
        let html = realFigure + realFigure
        XCTAssertEqual(parse(html).count, 1)
    }

    func testRespectsMaximumFigureCount() {
        let block = """
        <figure class="ltx_figure"><img src="2506.06962v3/f%INDEX%.png" width="400" height="300">\
        <figcaption>Figure %INDEX%: caption</figcaption></figure>
        """
        let html = (1...(ArxivHTMLFigureParser.maxFigures + 10))
            .map { block.replacingOccurrences(of: "%INDEX%", with: String($0)) }
            .joined()
        XCTAssertEqual(parse(html).count, ArxivHTMLFigureParser.maxFigures)
    }

    // MARK: URL 归一化

    func testAbsoluteURLResolution() {
        let page = "https://arxiv.org/html/2506.06962"
        // 带版本号的相对路径（真实情况）—— 不能再套一层 /html/<id>/
        XCTAssertEqual(ArxivHTMLFigureParser.absoluteURL("2506.06962v3/a.png", pageURL: page),
                       "https://arxiv.org/html/2506.06962v3/a.png")
        // 根相对
        XCTAssertEqual(ArxivHTMLFigureParser.absoluteURL("/html/2506.06962v3/a.png", pageURL: page),
                       "https://arxiv.org/html/2506.06962v3/a.png")
        // 已是绝对地址
        XCTAssertEqual(ArxivHTMLFigureParser.absoluteURL("https://cdn.example.com/a.png",
                                                        pageURL: page),
                       "https://cdn.example.com/a.png")
        // 协议相对
        XCTAssertEqual(ArxivHTMLFigureParser.absoluteURL("//cdn.example.com/a.png", pageURL: page),
                       "https://cdn.example.com/a.png")
        // 内联数据必须拒绝
        XCTAssertNil(ArxivHTMLFigureParser.absoluteURL("data:image/png;base64,AAAA",
                                                       pageURL: page))
        XCTAssertNil(ArxivHTMLFigureParser.absoluteURL("   ", pageURL: page))
    }

    // MARK: 图注处理

    func testLabelParsing() {
        XCTAssertEqual(ArxivHTMLFigureParser.splitLabel("Figure 1: hello").0,
                       "Figure 1")
        XCTAssertEqual(ArxivHTMLFigureParser.splitLabel("Fig. 2. hello").0,
                       "Figure 2")
        XCTAssertEqual(ArxivHTMLFigureParser.splitLabel("Table 3: hello").0,
                       "Table 3")
        XCTAssertEqual(ArxivHTMLFigureParser.splitLabel("Figure 12: hello").0,
                       "Figure 12")
        // 补充材料的限定词要保留，否则“Supplementary Figure 4”会被当成正文 Figure 4
        XCTAssertEqual(ArxivHTMLFigureParser.splitLabel("Supplementary Figure 4: x").0,
                       "Supplementary Figure 4")
        // 没有图号时只能给占位标签 —— **不能**伪造一个图号，
        // 否则用户在列表里看到“图 2”会以为是正文里的 Figure 2。
        XCTAssertEqual(ArxivHTMLFigureParser.splitLabel("no label here").0,
                       ArxivHTMLFigureParser.unnumberedLabel)
    }

    func testLabelIsStrippedFromCaption() {
        let (_, caption) = ArxivHTMLFigureParser.splitLabel("Figure 1: The actual caption.")
        XCTAssertEqual(caption, "The actual caption.")
    }

    /// 无图注的图要编号，但要用与真图号明显不同的名字。
    /// 素材：`2609.11877` 正文里的 `S2.SS4.fig1` / `S2.SS7.fig1`（论文本身只有 Figure 1）。
    func testCaptionlessFiguresGetHonestLabels() {
        let html = """
        <figure class="ltx_figure" id="S0.F1"><img src="v1/a.png" width="400" height="300">
        <figcaption>Figure 1: Real figure.</figcaption></figure>
        <figure class="ltx_figure" id="S2.SS4.fig1"><object data="v1/f4.svg" width="400" height="300"></object></figure>
        <figure class="ltx_figure" id="S2.SS7.fig1"><object data="v1/f6.svg" width="400" height="300"></object></figure>
        """
        let figures = ArxivHTMLFigureParser.parse(
            html: html, arxivID: "2609.11877", pageURL: "https://arxiv.org/html/2609.11877")

        XCTAssertEqual(figures.map(\.label),
                       ["Figure 1", "未编号插图 1", "未编号插图 2"])
        // 真正的 Figure 1 不能受影响
        XCTAssertFalse(figures.contains { $0.label == "图 2" })
    }

    /// `<object type="image/svg+xml" data="….svg">` 是矢量图，LaTeXML 用它输出一半的图。
    /// 漏掉就等于丢掉一半（实测 `2402.12317` 6 张里 5 张是 SVG）。
    func testObjectSvgFiguresAreExtracted() {
        let html = """
        <figure class="ltx_figure" id="S0.F1">
        <object type="image/svg+xml" data="2402.12317v1/fig1.svg" width="476" height="347"></object>
        <figcaption>Figure 1: Overview.</figcaption></figure>
        """
        let figures = ArxivHTMLFigureParser.parse(
            html: html, arxivID: "2402.12317", pageURL: "https://arxiv.org/html/2402.12317")

        XCTAssertEqual(figures.count, 1)
        XCTAssertEqual(figures[0].imageURL, "https://arxiv.org/html/2402.12317v1/fig1.svg")
        XCTAssertTrue(figures[0].isVector)
        XCTAssertEqual(figures[0].aspectRatio ?? 0, 476.0 / 347.0, accuracy: 0.001)
    }

    // MARK: 多子图面板

    /// 素材取自真实页面 `arxiv.org/html/2606.05868`：
    /// Figure 5 被 LaTeXML 拆成 `S3.F5`、`S3.F5.sf1`、`S3.F5.sf2` 三个块。
    func testPanelLabelUsesParentFigureNumber() {
        XCTAssertEqual(
            ArxivHTMLFigureParser.panelLabel(anchor: "S3.F5.sf1",
                                             caption: "(a) Tansition tajectory diagram."),
            "Figure 5 (a)")
        XCTAssertEqual(
            ArxivHTMLFigureParser.panelLabel(anchor: "S3.F5.sf2",
                                             caption: "(b) Transition trajectory diagram."),
            "Figure 5 (b)")
        // 外层 figure 块（锚点没有 .sf 后缀）也要能拿到父图号，
        // 否则它会退回按出现顺序编号，得到与正文引用对不上的“图 N”。
        XCTAssertEqual(
            ArxivHTMLFigureParser.panelLabel(anchor: "S3.F5",
                                             caption: "(a) Tansition tajectory diagram."),
            "Figure 5 (a)")
    }

    func testPanelLabelIgnoresNonPanels() {
        // 普通图注不以 (a) 开头
        XCTAssertNil(ArxivHTMLFigureParser.panelLabel(anchor: "S0.F1",
                                                      caption: "Overview of the system."))
        // 正文里的 “(a)” 引用不在开头
        XCTAssertNil(ArxivHTMLFigureParser.panelLabel(anchor: "S0.F1",
                                                      caption: "See (a) for details."))
        // 锚点里没有图号
        XCTAssertNil(ArxivHTMLFigureParser.panelLabel(anchor: "intro",
                                                      caption: "(a) something"))
    }

    func testFigureNumberExtraction() {
        XCTAssertEqual(ArxivHTMLFigureParser.figureNumber(from: "S0.F1"), 1)
        XCTAssertEqual(ArxivHTMLFigureParser.figureNumber(from: "A3.F7"), 7)
        XCTAssertEqual(ArxivHTMLFigureParser.figureNumber(from: "S3.F5.sf2"), 5)
        XCTAssertEqual(ArxivHTMLFigureParser.figureNumber(from: "S12.F10"), 10)
        XCTAssertNil(ArxivHTMLFigureParser.figureNumber(from: "S3.T1"))
    }

    /// 面板图注里不含 `Figure 5:`，所以 `splitLabel` 会返回占位标签；
    /// `panelLabel` 必须在解析阶段把它覆盖掉 —— 这里用真实 HTML 片段验证整条链路。
    func testParsingSubfiguresProducesDistinctPanelLabels() {
        let html = """
        <figure class="ltx_figure" id="S3.F5"><img src="v1/compare1.png" width="476" height="247">
        <figcaption class="ltx_caption">(a) Tansition tajectory diagram of TransMLA.</figcaption>
        </figure>
        <figure class="ltx_figure" id="S3.F5.sf2"><img src="v1/compare2.png" width="476" height="257">
        <figcaption class="ltx_caption">(b) Tansition tajectory diagram of layer-adaptive.</figcaption>
        </figure>
        """
        let figures = ArxivHTMLFigureParser.parse(
            html: html, arxivID: "2606.05868", pageURL: "https://arxiv.org/html/2606.05868")

        XCTAssertEqual(figures.map(\.label), ["Figure 5 (a)", "Figure 5 (b)"])
        // 标签唯一 —— 重复的话列表里两张图会看起来像同一张
        XCTAssertEqual(Set(figures.map(\.label)).count, figures.count)
    }

    func testEntityDecoding() {
        XCTAssertEqual(ArxivHTMLFigureParser.decodeEntities("a &amp; b"), "a & b")
        XCTAssertEqual(ArxivHTMLFigureParser.decodeEntities("x &lt; y &gt; z"), "x < y > z")
        XCTAssertEqual(ArxivHTMLFigureParser.decodeEntities("2014&#8212;2024"), "2014—2024")
        XCTAssertEqual(ArxivHTMLFigureParser.decodeEntities("&#x2014;"), "—")
        // 空白折叠
        XCTAssertEqual(ArxivHTMLFigureParser.decodeEntities("a \n  b\t c"), "a b c")
    }

    // MARK: arXiv ID

    func testArxivIDExtraction() {
        XCTAssertEqual(FigureExtractor.arxivID(from: "https://arxiv.org/abs/2506.06962"),
                       "2506.06962")
        XCTAssertEqual(FigureExtractor.arxivID(from: "https://arxiv.org/abs/2506.06962v3"),
                       "2506.06962v3")
        XCTAssertNil(FigureExtractor.arxivID(from: "https://example.com/abs/1"))
    }

    // MARK: 缓存模型往返

    func testFigureSetCodableRoundTrip() throws {
        // 用整秒时间：JSONEncoder 的 .iso8601 只精确到秒，
        // 否则会出现"打印出来一模一样、但 == 为 false"的假失败
        let original = PaperFigureSet(
            arxivID: "2506.06962",
            sourceURL: "https://arxiv.org/html/2506.06962",
            figures: [PaperFigure(imageURL: "https://arxiv.org/html/2506.06962v3/a.png",
                                  label: "Figure 1", caption: "示例图注",
                                  width: 419, height: 214)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            note: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(PaperFigureSet.self,
                                         from: try encoder.encode(original))
        XCTAssertEqual(restored, original)
    }

    // MARK: 核心图选取

    /// 复刻 2506.06962 的真实数据（引用次数取自实际页面统计）。
    ///
    /// 关键点：Figure 5 的引用次数（5）**高于** Figure 1（4），
    /// 但 Figure 1 是首图且图注含 "Comparison"，最终应选中 Figure 1 ——
    /// 这与人工判断一致（Figure 1 是总览对比图）。
    private func realFigureSet() -> [PaperFigure] {
        func make(_ n: Int, _ caption: String, refs: Int, appendix: Bool = false) -> PaperFigure {
            PaperFigure(imageURL: "https://arxiv.org/html/2506.06962v3/f\(n).png",
                        label: "Figure \(n)", caption: caption,
                        width: 430, height: 200,
                        referenceCount: refs, isAppendix: appendix)
        }
        return [
            make(1, "Comparison between Autoregressive Retrieval Augmentation and existing paradigms", refs: 4),
            make(2, "The decoding process in Distribution-Augmentation in Decoding", refs: 1),
            make(3, "Overall architecture of Feature-Augmentation in Decoding", refs: 1),
            make(4, "Qualitative results of DAiD, FAiD and baselines", refs: 1),
            make(5, "Images generated by ImageRAG and our method", refs: 5),
            make(6, "l2 distance between ground-truth tokens and targets", refs: 1, appendix: true),
            make(7, "Hyperparameter optimization results", refs: 1, appendix: true),
        ]
    }

    func testSelectsTeaserFigureOverMoreReferencedOne() {
        let selected = KeyFigureSelector.select(from: realFigureSet())
        XCTAssertEqual(selected?.label, "Figure 1",
                       "应选总览图而不是被引次数更多的定性结果图")
    }

    func testAppendixFiguresAreDownweighted() {
        // 附录图即使被引很多，也不该当门面
        let figures = [
            PaperFigure(imageURL: "a", label: "Figure 1", caption: "overview",
                        width: 400, height: 300, referenceCount: 1, isAppendix: false),
            PaperFigure(imageURL: "b", label: "Figure 2", caption: "extra results",
                        width: 400, height: 300, referenceCount: 20, isAppendix: true),
        ]
        XCTAssertEqual(KeyFigureSelector.select(from: figures)?.imageURL, "a")
    }

    /// 回归测试：**论文的总览图在正文里可能一次都没被引用**。
    ///
    /// 素材是 `2306.00978`（AWQ）的真实数据：Figure 1 是方法总览图，
    /// 但页面里对 `#S1.F1` 的引用次数经核实是 **0** —— 图形摘要本来就是让人看的，
    /// 没人会在正文里写"见图 1"；而被引 4 次的是实验节的消融图 Figure 8。
    ///
    /// 这条是踩坑后加的：早期版本给引用次数 2.0 的权重，会选中 Figure 8。
    func testTeaserWithZeroReferencesStillWins() {
        let figures = [
            PaperFigure(imageURL: "f1", label: "Figure 1",
                        caption: "We introduce AWQ, a versatile weight quantization method for LLM.",
                        width: 430, height: 200, referenceCount: 0),
            PaperFigure(imageURL: "f2", label: "Figure 2",
                        caption: "We observe that we can find 1% of the salient weights",
                        width: 430, height: 200, referenceCount: 2),
            PaperFigure(imageURL: "f3", label: "Figure 3",
                        caption: "Bottleneck analysis for Llama-2-7B on NVIDIA RTX 4090.",
                        width: 430, height: 200, referenceCount: 4),
            PaperFigure(imageURL: "f4", label: "Figure 4",
                        caption: "SIMD-aware weight packing for ARM NEON.",
                        width: 430, height: 200, referenceCount: 1),
            PaperFigure(imageURL: "f8", label: "Figure 8",
                        caption: "Left: AWQ needs a much smaller calibration set to reach a good quantized performance. It can achieve better perplexity using 10× smaller calibration set compared to GPTQ. Right: Our method is more robust to the calibration set distribution.",
                        width: 430, height: 200, referenceCount: 4),
        ]
        XCTAssertEqual(KeyFigureSelector.select(from: figures)?.imageURL, "f1",
                       "首图加成应当纠正“总览图零引用”带来的误导")
    }

    /// 图注后半段提到的 "our method" 不应被算作总览信号。
    ///
    /// 素材同样来自 `2306.00978` 的 Figure 8（消融图）：它在第 184 个字符处写
    /// "Right: Our method is more robust to the calibration set distribution"，
    /// 旧版按整段图注匹配关键词时，这张消融图会反超总览图。
    func testKeywordDeepInCaptionDoesNotCount() {
        let ablation = PaperFigure(
            imageURL: "deep",
            label: "Figure 8",
            caption: "Left: AWQ needs a much smaller calibration set to reach a good "
                + "quantized performance. Right: Our method is more robust to the "
                + "calibration set distribution.",
            width: 430, height: 200, referenceCount: 4)
        let shallow = PaperFigure(
            imageURL: "shallow",
            label: "Figure 2",
            caption: "Illustration of our method pipeline.",
            width: 430, height: 200, referenceCount: 0)

        // 同一个位置上的图，只看开头的话前者拿不到关键词分
        let deepScore = KeyFigureSelector.score(ablation, index: 1, total: 2)
        let shallowScore = KeyFigureSelector.score(shallow, index: 1, total: 2)
        XCTAssertGreaterThan(shallowScore, deepScore)
    }

    /// 反方向：图注明写 "Overview of our … framework" 时，即使不是首图也要胜出。
    ///
    /// 素材是 `2608.10703` 的真实数据（Figure 2 才是总览图，Figure 1 不是）。
    func testExplicitOverviewCaptionBeatsFirstFigure() {
        let figures = [
            PaperFigure(imageURL: "f1", label: "Figure 1",
                        caption: "From questionnaire self-report to situated, controllable behavioral measures.",
                        width: 430, height: 200, referenceCount: 0),
            PaperFigure(imageURL: "f2", label: "Figure 2",
                        caption: "Overview of our situated B-data framework. (i) From validated psychometric scales",
                        width: 430, height: 200, referenceCount: 4),
        ]
        XCTAssertEqual(KeyFigureSelector.select(from: figures)?.imageURL, "f2")
    }

    /// 图注明写 "Overview of the proposed framework" 时，结果类图不该赢。
    ///
    ///（旧版给引用次数 2.0 的权重，靠"首图 + 引用"会把 "Some results table" 顶上来；
    /// 加入实验类负向词后，明确的总览图注才能胜出。）
    func testArchitectureCaptionBeatsResultsFigure() {
        let figures = [
            PaperFigure(imageURL: "a", label: "Figure 1", caption: "Some results table",
                        width: 400, height: 300, referenceCount: 2),
            PaperFigure(imageURL: "b", label: "Figure 2", caption: "Overview of the proposed framework",
                        width: 400, height: 300, referenceCount: 2),
        ]
        XCTAssertEqual(KeyFigureSelector.select(from: figures)?.imageURL, "b")

        // 但首图自己就是总览图时，位置优势要能压过同分的后来者
        let reversed = [
            PaperFigure(imageURL: "a", label: "Figure 1", caption: "Overview of our method",
                        width: 400, height: 300, referenceCount: 2),
            PaperFigure(imageURL: "b", label: "Figure 2", caption: "Overview of the framework",
                        width: 400, height: 300, referenceCount: 2),
        ]
        XCTAssertEqual(KeyFigureSelector.select(from: reversed)?.imageURL, "a")
    }

    /// 消融图：图注用词和总览图很像，靠负向词才能压住。
    /// 素材是 `2507.22171` 的 Figure 4 vs Figure 2。
    func testAblationCaptionDoesNotWinEvenWithOverviewWords() {
        let figures = [
            PaperFigure(imageURL: "f1", label: "Figure 1",
                        caption: "Persona prompts for jailbreaking.",
                        width: 430, height: 200, referenceCount: 1),
            PaperFigure(imageURL: "f2", label: "Figure 2",
                        caption: "The proposed framework. The population maintains a constant size",
                        width: 430, height: 200, referenceCount: 1),
            PaperFigure(imageURL: "f4", label: "Figure 4",
                        caption: "Ablation study of crossover and mutation operations in our proposed pipeline.",
                        width: 430, height: 200, referenceCount: 2),
        ]
        XCTAssertEqual(KeyFigureSelector.select(from: figures)?.imageURL, "f2")
    }

    func testSelectorHandlesEmptyAndSingle() {
        XCTAssertNil(KeyFigureSelector.select(from: []))
        let only = PaperFigure(imageURL: "a", label: "Figure 1", caption: "",
                               width: 400, height: 300)
        XCTAssertEqual(KeyFigureSelector.select(from: [only])?.imageURL, "a")
    }

    /// 已知下载不到的图要跳过，退而选下一张。
    ///
    /// 素材：`2404.07677` 的 `latex/figs/` 子目录在 arXiv 上根本没发布，
    /// 图片 404（已用 HTTP 请求核实）。若不跳过，那一行就是永远的空框。
    func testBrokenImageIsSkippedInFavorOfNextFigure() {
        let figures = [
            PaperFigure(imageURL: "broken", label: "Figure 1",
                        caption: "Overview of the proposed framework",
                        width: 400, height: 300, referenceCount: 3),
            PaperFigure(imageURL: "good", label: "Figure 2",
                        caption: "Some results table",
                        width: 400, height: 300, referenceCount: 0),
        ]
        // 正常情况选 Figure 1（首图 + 总览关键词）
        XCTAssertEqual(KeyFigureSelector.select(from: figures)?.imageURL, "broken")
        // 已知它是坏图时，退而选 Figure 2
        XCTAssertEqual(
            KeyFigureSelector.select(from: figures, excluding: ["broken"])?.imageURL,
            "good")
    }

    /// 全部都是坏图时退回第一张：宁可显示"加载失败"，
    /// 也不要整个区块消失（用户会以为功能坏了）。
    func testAllBrokenFallsBackToFirstFigure() {
        let figures = [
            PaperFigure(imageURL: "a", label: "Figure 1", caption: "",
                        width: 400, height: 300),
            PaperFigure(imageURL: "b", label: "Figure 2", caption: "",
                        width: 400, height: 300),
        ]
        XCTAssertEqual(
            KeyFigureSelector.select(from: figures, excluding: ["a", "b"])?.imageURL,
            "a")
    }

    // MARK: 引用次数统计

    func testReferenceCountingUsesTitleAttribute() {
        // 真实形态：可见文字只有数字，图号在 title 里
        let html = """
        <p>as shown in <a href="#S0.F1" title="Figure 1 ‣ Paper Title" \
        class="ltx_ref"><span class="ltx_text ltx_ref_tag">1</span></a> and again \
        <a href="#S0.F1" title="Figure 1 ‣ Paper Title" class="ltx_ref">\
        <span>1</span></a>, while <a href="#S0.F5" title="Figure 5 ‣ Paper Title" \
        class="ltx_ref"><span>5</span></a> appears once. \
        <a href="#S2.SS1" title="In 2 Preliminary ‣ Paper Title" class="ltx_ref">\
        <span>2</span></a> is a section reference.</p>
        """
        let counts = ArxivHTMLFigureParser.referenceCounts(in: html)
        XCTAssertEqual(counts["S0.F1"], 2)
        XCTAssertEqual(counts["S0.F5"], 1)
        XCTAssertNil(counts["S2.SS1"], "章节引用不应计入")
    }

    func testSubfigureReferencesAreSummedIntoParent() {
        let html = """
        <a href="#S0.F1" title="Figure 1 ‣ T" class="ltx_ref">1</a>
        <a href="#S0.F1.g2" title="Figure 1 ‣ T" class="ltx_ref">1</a>
        <a href="#S0.F10" title="Figure 10 ‣ T" class="ltx_ref">10</a>
        """
        let counts = ArxivHTMLFigureParser.referenceCounts(in: html)
        // F1 与子图 F1.g2 合并
        XCTAssertEqual(ArxivHTMLFigureParser.referenceCount(for: "S0.F1", in: counts), 2)
        // 不能把 F10 误算进 F1
        XCTAssertEqual(ArxivHTMLFigureParser.referenceCount(for: "S0.F10", in: counts), 1)
    }

    func testTableAndAlgorithmReferencesIgnored() {
        let html = """
        <a href="#S3.T1" title="Table 1 ‣ T" class="ltx_ref">1</a>
        <a href="#alg1" title="Algorithm 1 ‣ T" class="ltx_ref">1</a>
        <a href="#S0.F2" title="Figure 2 ‣ T" class="ltx_ref">2</a>
        """
        let counts = ArxivHTMLFigureParser.referenceCounts(in: html)
        XCTAssertNil(counts["S3.T1"])
        XCTAssertNil(counts["alg1"])
        XCTAssertEqual(counts["S0.F2"], 1)
    }

    func testAppendixAnchorDetection() {
        XCTAssertTrue(ArxivHTMLFigureParser.isAppendixAnchor("A3.F7"))
        XCTAssertTrue(ArxivHTMLFigureParser.isAppendixAnchor("A1.F2"))
        XCTAssertFalse(ArxivHTMLFigureParser.isAppendixAnchor("S3.F2"))
        XCTAssertFalse(ArxivHTMLFigureParser.isAppendixAnchor("alg1"))
        XCTAssertFalse(ArxivHTMLFigureParser.isAppendixAnchor(""))
    }

    func testParsesReferenceCountsAndAppendixFlagsFromHTML() throws {
        let html = """
        <p>See <a href="#S3.F2" title="Figure 2 ‣ T" class="ltx_ref">2</a> \
        and <a href="#S3.F2" title="Figure 2 ‣ T" class="ltx_ref">2</a>.</p>
        <figure id="S3.F2" class="ltx_figure"><img src="2506.06962v3/main.png" \
        width="600" height="300"><figcaption>Figure 2: Overall architecture.</figcaption></figure>
        <figure id="A1.F1" class="ltx_figure"><img src="2506.06962v3/appendix.png" \
        width="600" height="300"><figcaption>Figure 5: Extra.</figcaption></figure>
        """
        let figures = parse(html)
        XCTAssertEqual(figures.count, 2)

        let main = try XCTUnwrap(figures.first { $0.label == "Figure 2" })
        XCTAssertEqual(main.referenceCount, 2)
        XCTAssertFalse(main.isAppendix)

        let appendix = try XCTUnwrap(figures.first { $0.label == "Figure 5" })
        XCTAssertTrue(appendix.isAppendix, "锚点以 A 开头应识别为附录")
    }

    func testSupplementaryFigureLabelAndAppendixFlag() throws {
        let html = """
        <figure id="A2.F4" class="ltx_figure"><img src="2506.06962v3/s.png" \
        width="600" height="300"><figcaption>Supplementary Figure 4: BPMF embeddings.</figcaption></figure>
        """
        let figure = try XCTUnwrap(parse(html).first)
        XCTAssertEqual(figure.label, "Supplementary Figure 4")
        XCTAssertEqual(figure.caption, "BPMF embeddings.")
        XCTAssertTrue(figure.isAppendix)
    }

    // MARK: 核心图 / 其余图

    func testKeyFigureAndOthersPartition() {
        let figures = realFigureSet()
        let set = PaperFigureSet(arxivID: "2506.06962", figures: figures,
                                 keyFigureID: figures[0].imageURL)
        XCTAssertEqual(set.keyFigure?.label, "Figure 1")
        XCTAssertEqual(set.otherFigures.count, figures.count - 1)
        XCTAssertFalse(set.otherFigures.contains { $0.imageURL == figures[0].imageURL },
                       "底部列表不应重复核心图")
    }

    func testKeyFigureFallsBackToFirstWhenUnset() {
        let figures = realFigureSet()
        let set = PaperFigureSet(arxivID: "2506.06962", figures: figures)
        XCTAssertEqual(set.keyFigure?.label, "Figure 1")

        let stale = PaperFigureSet(arxivID: "x", figures: figures, keyFigureID: "不存在的地址")
        XCTAssertEqual(stale.keyFigure?.label, "Figure 1", "失效的 keyFigureID 应回退")
    }

    /// 核心图在**读取时重算**，落盘的 `keyFigureID` 只作记录。
    ///
    /// 否则调整打分权重后，旧缓存会一直显示按旧权重选出的图 ——
    /// 这个坑真实发生过：改完权重后 App 里仍显示旧选择，因为缓存里存着
    /// 抓取当时的结论，而重算让调参不需要重下任何页面。
    func testStaleKeyFigureIDIsRecomputedOnRead() {
        let figures = realFigureSet()
        // 故意把 keyFigureID 写成按旧权重会选中的那张（被引更多的 Figure 5）
        let set = PaperFigureSet(arxivID: "2506.06962", figures: figures,
                                 keyFigureID: figures[4].imageURL)
        XCTAssertEqual(set.keyFigure?.label, "Figure 1",
                       "应以当前权重重算，而不是沿用落盘结果")
    }

    // MARK: 作者机构

    /// 素材取自真实页面 `arxiv.org/html/2606.05868` 的作者块。
    /// 注意机构那一层里面还嵌着一个 `ltx_contact_name` 的 span（内容是 "Affiliation: "），
    /// 简单截到第一个 `</span>` 会把机构名切掉一半。
    func testAffiliationExtractionFromRealMarkup() {
        let html = """
        <div class="ltx_authors"><span class="ltx_creator ltx_role_author">
        <span class="ltx_personname">PSBC &amp; Huawei LLM Team </span>
        <span class="ltx_author_notes"><span class="ltx_author_notes_content">
        <span class="ltx_contact ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span>Postal Savings Bank of China, Beijing, China </span>
        <span class="ltx_contact ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span>Huawei Technologies, Shenzhen, China </span>
        </span></span></span></div>
        """
        XCTAssertEqual(ArxivHTMLFigureParser.affiliations(in: html),
                       ["Postal Savings Bank of China, Beijing, China",
                        "Huawei Technologies, Shenzhen, China"])
    }

    /// 去重：`2402.10517` 的作者块里 "Seoul National University" 出现了 5 次。
    func testAffiliationsAreDeduplicated() {
        let one = #"<span class="ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span>Seoul National University</span>"#
        let html = String(repeating: one, count: 5)
        XCTAssertEqual(ArxivHTMLFigureParser.affiliations(in: html),
                       ["Seoul National University"])
    }

    /// `2609.11877` 里混进了非机构内容，必须滤掉。
    func testAffiliationNoiseIsFiltered() {
        let html = """
        <span class="ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span>Genentech, South San Francisco, CA, USA</span>
        <span class="ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span>These authors contributed equally</span>
        <span class="ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span>Email: someone@example.edu</span>
        <span class="ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span>https://example.org/lab</span>
        <span class="ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span>Corresponding author</span>
        """
        XCTAssertEqual(ArxivHTMLFigureParser.affiliations(in: html),
                       ["Genentech, South San Francisco, CA, USA"])
    }

    /// 被误标成机构的人名要丢掉，同时不能误伤正常机构。
    /// 真实案例：`2609.11877` 把作者 "Namkyeong Lee" 标成了 affiliation。
    func testPersonNameMislabelIsDropped() {
        XCTAssertTrue(ArxivHTMLFigureParser.looksLikePersonName("Namkyeong Lee"))
        XCTAssertTrue(ArxivHTMLFigureParser.looksLikePersonName("Zheng Zhang"))

        // 单词机构（合法）不能被当成人名
        XCTAssertFalse(ArxivHTMLFigureParser.looksLikePersonName("Meta"))
        XCTAssertFalse(ArxivHTMLFigureParser.looksLikePersonName("DeepMind"))
        // 带逗号的地址式机构
        XCTAssertFalse(ArxivHTMLFigureParser.looksLikePersonName(
            "Huawei Technologies, Shenzhen, China"))
        // 带机构后缀的两词机构
        XCTAssertFalse(ArxivHTMLFigureParser.looksLikePersonName("Tsinghua University"))
        XCTAssertFalse(ArxivHTMLFigureParser.looksLikePersonName("Allen Institute"))
        XCTAssertFalse(ArxivHTMLFigureParser.looksLikePersonName("Google Research"))
    }

    /// 有的论文把全部机构塞进同一个 affiliation 块，用分号分隔并加 `<sup>` 序号。
    /// 素材逐字取自真实页面 `arxiv.org/html/2609.08977`。
    func testMultipleInstitutionsInOneBlockAreSplit() {
        let html = """
        <span class="ltx_contact ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span><sup id="id1" class="ltx_sup">1</sup>Hunyuan Speech Team, Tencent; <sup id="id2" class="ltx_sup">2</sup>Zhejiang University; <sup id="id3" class="ltx_sup">3</sup>Shanghai Jiao Tong University </span>
        """
        XCTAssertEqual(ArxivHTMLFigureParser.affiliations(in: html),
                       ["Hunyuan Speech Team, Tencent",
                        "Zhejiang University",
                        "Shanghai Jiao Tong University"])
    }

    /// 数字开头的**真机构名**不能被削（`3M` 是合法公司名）。
    /// 早期版本按"数字 + 大写字母"剥序号，把 `3M Company` 削成了 `M Company`。
    func testNumericInstitutionNameIsPreserved() {
        XCTAssertEqual(
            ArxivHTMLFigureParser.splitAffiliationEntries("3M Company"),
            ["3M Company"])
        // 而序号后面跟着两个以上字母时正常剥掉
        XCTAssertEqual(
            ArxivHTMLFigureParser.strippingLeadingIndex("1Stanford"),
            "Stanford")
        XCTAssertEqual(
            ArxivHTMLFigureParser.strippingLeadingIndex("12Zhejiang University"),
            "Zhejiang University")
        // 单个字母的机构缩写（3M）保持不变
        XCTAssertEqual(
            ArxivHTMLFigureParser.strippingLeadingIndex("3M Company"),
            "3M Company")
    }

    /// 没有作者块 / 没有机构标记时返回空数组，而不是报错或塞入垃圾。
    func testAffiliationExtractionOnPageWithoutAffiliations() {
        XCTAssertEqual(ArxivHTMLFigureParser.affiliations(in: "<html><body>nope</body></html>"),
                       [])
    }

    /// `affiliations` 不能被 `<figure>` 里同名的 class 干扰（两处都用 ltx_* 前缀）。
    func testAffiliationExtractionIgnoresFigures() {
        let html = """
        <figure class="ltx_figure"><img src="v1/a.png" width="400" height="300"></figure>
        """
        XCTAssertEqual(ArxivHTMLFigureParser.affiliations(in: html), [])
    }

    // MARK: 联网集成测试（默认跳过）

    /// 对真实的 arXiv 页面跑一遍完整链路。
    ///
    /// 默认跳过：单元测试套件不应该依赖外网，否则网络一抖就"测试失败"，
    /// 久而久之大家就不看测试结果了。需要时手动开：
    ///
    ///     LIVE_FIGURE_TEST=1 swift test --filter testLiveArxivPageExtraction
    ///     LIVE_FIGURE_TEST=1 LIVE_FIGURE_ID=2402.12317 swift test --filter testLiveArxivPageExtraction
    func testLiveArxivPageExtraction() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LIVE_FIGURE_TEST"] == "1",
            "联网测试默认跳过；设 LIVE_FIGURE_TEST=1 手动开启")

        let arxivID = ProcessInfo.processInfo.environment["LIVE_FIGURE_ID"] ?? "2506.06962"
        let extractor = FigureExtractor()
        let set = await extractor.fetch(arxivID: arxivID)

        XCTAssertNil(set.note, "真实页面不应报错：\(set.note ?? "")")
        // 不假设具体篇数：不同论文的插图数差别很大
        //（2506.06962 有 7 张，2402.12317 只有 1 张）。
        // 关键是**不能混进页面装饰元素** —— 后者由下面的断言守住。
        XCTAssertGreaterThanOrEqual(set.figures.count, 1, "至少应提取到 1 张图")

        let first = try XCTUnwrap(set.figures.first)
        XCTAssertTrue(first.imageURL.hasPrefix("https://arxiv.org/html/\(arxivID)v"),
                      "图片地址异常：\(first.imageURL)")
        XCTAssertFalse(first.caption.isEmpty, "图注不应为空")
        XCTAssertTrue(first.label.hasPrefix("Figure"), "标签应形如 Figure N，实际 \(first.label)")

        // 必须排除 arXiv 页面自身的装饰图（顶栏 logo、页脚赞助商 logo、data: 内联图）
        for figure in set.figures {
            XCTAssertFalse(figure.imageURL.contains("/static/"),
                           "混进了 arXiv 页面装饰图：\(figure.imageURL)")
            XCTAssertFalse(figure.imageURL.hasPrefix("data:"),
                           "混进了内联 data: 图片")
            XCTAssertFalse(figure.imageURL.contains("/html/\(arxivID)/\(arxivID)v"),
                           "URL 拼接错误：\(figure.imageURL)")
        }

        // 标签不应重复（重复通常意味着块切分错了）
        let labels = set.figures.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "出现了重复的图号：\(labels)")

        // 核心图必须选出来，且必须在候选集中
        let key = try XCTUnwrap(set.keyFigure, "没有选出核心图")
        XCTAssertTrue(set.figures.contains { $0.imageURL == key.imageURL })

        // 默认那篇的人工判断结果是 Figure 1（总览对比图）
        if arxivID == "2506.06962" {
            XCTAssertEqual(key.label, "Figure 1",
                           "人工判断该论文的核心图是 Figure 1（总览对比图）")
            XCTAssertEqual(set.otherFigures.count, set.figures.count - 1)
        }

        print("✅ [\(arxivID)] 提取到 \(set.figures.count) 张图："
              + labels.joined(separator: ", "))
        print("   核心图 → \(key.label)（被引 \(key.referenceCount) 次，"
              + "附录=\(key.isAppendix)）｜ \(key.caption.prefix(50))")
        print("   机构 → \(set.institutions.isEmpty ? "（未标注）" : set.institutions.joined(separator: " / "))")
    }
}
