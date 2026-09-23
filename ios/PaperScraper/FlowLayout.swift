//
//  FlowLayout.swift
//  PaperScraper
//

import SwiftUI

/// 会自动换行的横向布局。
///
/// 为什么需要自己写
/// --------------
/// 论文列表每行的评分 chip 数量是**用户可配置的**（最多 7 个），
/// 而正文列宽度被左侧评分徽标和右侧缩略图挤得只剩一百多点。
///
/// 之前用 `ViewThatFits` 在"三个并排 / 两个并排 / 换行"之间降级，
/// 结果是每行只放 2 个 chip，右侧留出一大片空白 —— 用户看到的
/// "「时效」「标题」右边有较大空白"就是这个原因。
///
/// `HStack` 不会换行，`LazyVGrid` 需要预先知道列数（而每个 chip 宽度不一），
/// 所以用 `Layout` 实现一个按**实际测量宽度**逐行填充的流式布局：
/// 每一行都尽量塞满，塞不下才换行。
struct FlowLayout: Layout {

    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity

        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                // 这一行放不下了：换行
                y += lineHeight + lineSpacing
                widest = max(widest, x)
                x = 0
                lineHeight = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, x)

        // 单行时高度只算一行，不要多出 lineSpacing
        let height = subviews.isEmpty ? 0 : y + lineHeight
        return CGSize(width: min(widest, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout Void) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > bounds.width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += x > 0 ? spacing : 0

            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}
