//
//  Paginator.swift
//  NovelReader
//
//  分页引擎：用 Core Text 逐行排版，按可用高度精确切页
//  - 不依赖 UITextView，分页结果可直接映射到字符范围
//  - 字号/行距/屏幕旋转变化后重排，并可按字符偏移回到原位置
//

import SwiftUI
import UIKit
import CoreText

// MARK: - 分页器

struct Paginator {

    /// 把整章文本按容器尺寸切页
    /// - Returns: 每页在原文中的 NSRange
    static func paginate(
        text: String,
        size: CGSize,
        font: UIFont,
        lineSpacing: CGFloat,
        color: UIColor = .label
    ) -> [NSRange] {
        let ns = text as NSString
        let total = ns.length
        guard total > 0 else { return [NSRange(location: 0, length: 0)] }
        guard size.width > 20, size.height > 20 else { return [NSRange(location: 0, length: total)] }

        let attributed = makeAttributedString(text: text, font: font, lineSpacing: lineSpacing, color: color)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        var pages: [NSRange] = []
        var location = 0
        let rect = CGRect(origin: .zero, size: size)
        let path = CGPath(rect: rect, transform: nil)

        var guardCount = 0
        while location < total && guardCount < 20_000 {
            guardCount += 1
            // 注意：range 是相对整串的绝对范围，从 location 排到末尾
            let remaining = CFRange(location: location, length: total - location)
            let frame = CTFramesetterCreateFrame(framesetter, remaining, path, nil)

            // CTFrameGetVisibleStringRange 返回的也是绝对位置，直接取 length 即本页字符数
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            var consumed = visibleRange.length

            if consumed <= 0 {
                // 极端情况：一个字符都放不下（容器太小），强制前进，避免死循环
                consumed = min(1, total - location)
            }

            // 尽量断在自然换行处，避免一页结尾把段落截成两半
            if location + consumed < total {
                consumed = adjustToNaturalBreak(ns: ns, start: location, length: consumed)
            }
            if consumed <= 0 { consumed = 1 }
            // 不允许超过剩余长度
            consumed = min(consumed, total - location)

            pages.append(NSRange(location: location, length: consumed))
            location += consumed
        }
        if pages.isEmpty {
            pages = [NSRange(location: 0, length: total)]
        }
        return pages
    }

    /// 让翻页断点更自然：优先断在换行符后
    private static func adjustToNaturalBreak(ns: NSString, start: Int, length: Int) -> Int {
        let end = start + length
        guard end <= ns.length, length > 8 else { return length }
        // 往回找最多 120 个字符里的换行
        let searchStart = max(start + 1, end - 120)
        let range = NSRange(location: searchStart, length: end - searchStart)
        let newline = ns.range(of: "\n", options: .backwards, range: range)
        if newline.location != NSNotFound, newline.location > start {
            return newline.location + newline.length - start
        }
        return length
    }

    static func makeAttributedString(text: String, font: UIFont, lineSpacing: CGFloat, color: UIColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byCharWrapping
        style.alignment = .justified
        style.paragraphSpacingBefore = 0
        style.paragraphSpacing = 0
        style.firstLineHeadIndent = 0
        style.headIndent = 0
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
            .kern: 0.2
        ])
    }

    /// 单行高度（用于行高计算和排版保险）
    static func lineHeight(font: UIFont, lineSpacing: CGFloat) -> CGFloat {
        font.lineHeight + lineSpacing
    }
}

// MARK: - Core Text 绘制视图

final class CoreTextPageView: UIView {
    private var framesetter: CTFramesetter?
    private var range: CFRange = CFRange(location: 0, length: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    func setContent(attributed: NSAttributedString, range: NSRange) {
        self.framesetter = CTFramesetterCreateWithAttributedString(attributed)
        self.range = CFRange(location: range.location, length: range.length)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let framesetter else { return }
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        let path = CGPath(rect: bounds, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
        CTFrameDraw(frame, ctx)
    }
}

struct CoreTextPage: UIViewRepresentable {
    let attributed: NSAttributedString
    let range: NSRange

    func makeUIView(context: Context) -> CoreTextPageView {
        CoreTextPageView()
    }

    func updateUIView(_ view: CoreTextPageView, context: Context) {
        view.setContent(attributed: attributed, range: range)
    }
}

// MARK: - 测量辅助：给定文本与尺寸，返回能放下的字符数

enum TextMeasurer {
    /// 计算一段文本在指定宽度下的总高度（用于预估）
    static func height(of text: String, width: CGFloat, font: UIFont, lineSpacing: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let attributed = Paginator.makeAttributedString(text: text, font: font, lineSpacing: lineSpacing, color: .black)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: attributed.length), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return ceil(size.height)
    }
}
