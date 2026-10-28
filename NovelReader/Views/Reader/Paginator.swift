//
//  Paginator.swift
//  NovelReader
//
//  分页引擎：用 Core Text 逐行排版，按可用高度精确切页
//  - 不依赖 UITextView，分页结果可直接映射到字符范围
//  - 字号/行距/屏幕旋转变化后重排，并可按字符偏移回到原位置
//
//  性能要点（滑动卡顿的修复核心）：
//  1. CTFramesetter 只建一次，跟着整章内容一起缓存；原来每次 updateUIView
//     都重建一次，一页翻三次就建三次，是卡顿主因之一。
//  2. CTFrame 按「本页 range + 当前 bounds」算出来，二者都没变就复用，
//     draw 阶段不再做任何排版。
//  3. 排版（paginateAsync）放到后台线程，翻章时不再卡主线程。
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
        return paginate(attributed: attributed, size: size)
    }

    /// 已建好 attributed 时的分页（滚动模式复用同一份 attributed，避免重复构造）
    static func paginate(attributed: NSAttributedString, size: CGSize) -> [NSRange] {
        let total = attributed.length
        guard total > 0 else { return [NSRange(location: 0, length: 0)] }
        guard size.width > 20, size.height > 20 else { return [NSRange(location: 0, length: total)] }

        let ns = attributed.string as NSString
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

    /// 后台线程分页：把「建 attributed string + 逐页排版」整体移出主线程。
    /// Core Text 的 framesetter 本身线程安全，这里只保证不碰 UIKit 视图。
    nonisolated static func paginateAsync(
        text: String,
        size: CGSize,
        font: UIFont,
        lineSpacing: CGFloat,
        color: UIColor
    ) async -> [NSRange] {
        await Task.detached(priority: .userInitiated) {
            let attributed = makeAttributedString(text: text, font: font, lineSpacing: lineSpacing, color: color)
            return paginate(attributed: attributed, size: size)
        }.value
    }
}

// MARK: - Core Text 绘制视图（分页模式）

/// 一页正文。framesetter 与 CTFrame 都做缓存，draw 阶段不再排版。
final class CoreTextPageView: UIView {
    private var framesetter: CTFramesetter?
    /// 缓存的页范围（CFRange，绝对位置）
    private var pageRange = CFRange(location: 0, length: 0)
    /// 已排版好的 CTFrame，与 pageRange + bounds 一一对应
    private var cachedFrame: CTFrame?
    private var cachedBounds: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 整章内容变了（换章 / 改字号 / 改行距 / 换主题色）
    /// 性能：相同 framesetter 直接跳过，避免滑动翻页时每帧重排版重绘（卡顿主因）
    func setFramesetter(_ newFramesetter: CTFramesetter?) {
        guard newFramesetter !== framesetter else { return }
        framesetter = newFramesetter
        cachedFrame = nil
        cachedBounds = .zero
        setNeedsDisplay()
    }

    /// 当前显示哪一页
    func setPageRange(_ range: CFRange) {
        guard range.location != pageRange.location || range.length != pageRange.length else { return }
        pageRange = range
        cachedFrame = nil
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 尺寸变了，frame 必须重算
        if bounds != cachedBounds {
            cachedFrame = nil
            setNeedsDisplay()
        }
    }

    private func makeFrameIfNeeded() -> CTFrame? {
        guard let framesetter else { return nil }
        if let cachedFrame, cachedBounds == bounds { return cachedFrame }
        let path = CGPath(rect: bounds, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, pageRange, path, nil)
        cachedFrame = frame
        cachedBounds = bounds
        return frame
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        guard let frame = makeFrameIfNeeded() else { return }

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}

struct CoreTextPage: UIViewRepresentable {
    /// 已缓存的整章 framesetter（关键：不再每帧重建）
    let framesetter: CTFramesetter?
    let range: NSRange

    func makeUIView(context: Context) -> CoreTextPageView {
        CoreTextPageView()
    }

    func updateUIView(_ view: CoreTextPageView, context: Context) {
        view.setFramesetter(framesetter)
        view.setPageRange(CFRange(location: range.location, length: range.length))
    }
}

// MARK: - 连续滚动视图（上下滑动模式）

/// 把整章文本按给定宽度排成一整版，输出高度供外层 UIScrollView 设置 contentSize。
/// 内部不做任何分页，滚动时不触发重新排版。
final class ContinuousTextView: UIView {
    private(set) var contentHeight: CGFloat = 0
    /// 供外层读的行索引探针高度（= contentHeight）
    var probeHeight: CGFloat { contentHeight }
    /// 是否显示滚动条外的溢出提示（保留字段，不影响排版）
    var clipsToLines: Bool = false

    private var framesetter: CTFramesetter?
    private var cachedFrame: CTFrame?
    private var cachedWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 设置内容，返回本版排版后的总高度
    @discardableResult
    func setContent(_ newFramesetter: CTFramesetter?, width: CGFloat) -> CGFloat {
        if newFramesetter !== framesetter || width != cachedWidth {
            framesetter = newFramesetter
            cachedFrame = nil
            layoutForWidth(width)
        }
        return contentHeight
    }

    private func layoutForWidth(_ width: CGFloat) {
        cachedWidth = width
        guard let framesetter, width > 0 else {
            contentHeight = 0
            return
        }
        // CFRange(0, 0) 表示「整串」，suggest 出的是当前宽度下的完整排版尺寸
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil)
        contentHeight = max(ceil(measured.height), 1)
        if frame.size.width != width || frame.size.height != contentHeight {
            frame.size = CGSize(width: width, height: contentHeight)
        }
        cachedFrame = nil
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, bounds.width != cachedWidth {
            layoutForWidth(bounds.width)
        }
    }

    /// 生成一版覆盖全部内容的 CTFrame，专供行原点反查用（不缓存，避免和绘制抢同一份）
    func makeLineProbeFrame() -> CTFrame? {
        guard let framesetter, cachedWidth > 0, contentHeight > 0 else { return nil }
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: cachedWidth, height: contentHeight),
                          transform: nil)
        return CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    }

    private func makeFrameIfNeeded() -> CTFrame? {
        guard let framesetter, bounds.width > 0, bounds.height > 0 else { return nil }
        if let cachedFrame { return cachedFrame }
        let path = CGPath(rect: CGRect(origin: .zero, size: bounds.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        cachedFrame = frame
        return frame
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        guard let frame = makeFrameIfNeeded() else { return }

        // 只绘制与可见区域相交的行，避免整章重绘（大章节上下滑动卡顿的关键）
        let visibleRect = rect.intersection(CGRect(origin: .zero, size: bounds.size))
        guard !visibleRect.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: visibleRect)
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}

/// 上下滑动模式的正文容器：
/// UIScrollView（纵向）+ 一整版 ContinuousTextView。
/// 滚动只改 contentOffset，不触发排版；松手时把偏移换算成字符位置回调出去。
struct ContinuousText: UIViewRepresentable {
    let framesetter: CTFramesetter?
    let length: Int
    let contentWidth: CGFloat
    let initialOffset: Int
    let onOffsetChange: (Int) -> Void
    let onReachBottom: () -> Void
    let onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOffsetChange: onOffsetChange,
                    onReachBottom: onReachBottom,
                    onTap: onTap)
    }

    func makeUIView(context: Context) -> ScrollableTextContainer {
        let view = ScrollableTextContainer()
        view.coordinator = context.coordinator
        view.onOffsetChange = onOffsetChange
        view.onReachBottom = onReachBottom
        view.onTap = onTap
        return view
    }

    func updateUIView(_ view: ScrollableTextContainer, context: Context) {
        view.coordinator = context.coordinator
        context.coordinator.onOffsetChange = onOffsetChange
        context.coordinator.onReachBottom = onReachBottom
        context.coordinator.onTap = onTap
        view.onOffsetChange = onOffsetChange
        view.onReachBottom = onReachBottom
        view.onTap = onTap
        view.apply(framesetter: framesetter,
                   width: contentWidth > 0 ? contentWidth : nil,
                   initialOffset: initialOffset)
    }

    final class Coordinator {
        var onOffsetChange: (Int) -> Void
        var onReachBottom: () -> Void
        var onTap: (CGPoint) -> Void

        init(onOffsetChange: @escaping (Int) -> Void,
             onReachBottom: @escaping () -> Void,
             onTap: @escaping (CGPoint) -> Void) {
            self.onOffsetChange = onOffsetChange
            self.onReachBottom = onReachBottom
            self.onTap = onTap
        }
    }
}

/// 纵向滚动的正文容器。滚动位置 → 字符偏移用 Core Text 的行原点精确反查。
final class ScrollableTextContainer: UIView, UIScrollViewDelegate {
    var coordinator: ContinuousText.Coordinator?
    var onOffsetChange: ((Int) -> Void)?
    var onReachBottom: (() -> Void)?
    var onTap: ((CGPoint) -> Void)?

    private let scrollView = UIScrollView()
    private let textView = ContinuousTextView()
    private var lastFramesetterIdentity: ObjectIdentifier?
    private var appliedWidth: CGFloat = 0
    private var didApplyInitialOffset = false
    /// 每行的顶部 y（从文字版顶端算）与该行起始字符偏移，升序
    private var lineTops: [CGFloat] = []
    private var lineStarts: [Int] = []
    private var lastReportedOffset = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        addSubview(scrollView)
        scrollView.addSubview(textView)
        textView.clipsToLines = false

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView.frame != bounds {
            scrollView.frame = bounds
        }
        layoutText()
    }

    func apply(framesetter: CTFramesetter?, width: CGFloat?, initialOffset: Int) {
        let identity = framesetter.map { ObjectIdentifier($0) }
        let widthChanged = width != nil && width != appliedWidth
        let contentChanged = identity != lastFramesetterIdentity

        if contentChanged || widthChanged {
            lastFramesetterIdentity = identity
            if let width { appliedWidth = width }
            didApplyInitialOffset = false
            textView.setContent(framesetter, width: appliedWidth)
            rebuildLineIndex()
            layoutText()
        }

        if !didApplyInitialOffset {
            didApplyInitialOffset = true
            scrollToCharOffset(initialOffset)
        }
    }

    private func layoutText() {
        let w = appliedWidth > 0 ? appliedWidth : bounds.width
        guard w > 0 else { return }
        let h = max(textView.contentHeight, 1)
        if textView.frame.size.width != w || textView.frame.size.height != h {
            textView.frame = CGRect(x: 0, y: 0, width: w, height: h)
        }
        let contentH = max(h, bounds.height)
        if scrollView.contentSize.height != contentH || scrollView.contentSize.width != bounds.width {
            scrollView.contentSize = CGSize(width: bounds.width, height: contentH)
        }
    }

    // MARK: - 行索引

    /// 用 CTFrame 的行原点建立「滚动 y → 字符偏移」的精确映射。
    /// CTFrameGetLineOrigins 给的是 Core Text 坐标（原点在左下），
    /// 这里统一换算成 UIKit 的「从顶端往下」坐标。
    private func rebuildLineIndex() {
        lineTops.removeAll()
        lineStarts.removeAll()
        guard let frame = textView.makeLineProbeFrame() else { return }
        let lines = CTFrameGetLines(frame) as NSArray
        let count = lines.count
        guard count > 0 else { return }
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let height = max(textView.probeHeight, 1)
        for i in 0..<count {
            let line = lines[i] as! CTLine
            let range = CTLineGetStringRange(line)
            // CT 原点在左下：top = 总高 - y - 行高
            let lineHeight = CTLineGetTypographicBounds(line, nil, nil, nil)
            let top = height - origins[i].y - CGFloat(lineHeight)
            lineTops.append(top)
            lineStarts.append(range.location)
        }
    }

    private func scrollToCharOffset(_ offset: Int) {
        guard !lineStarts.isEmpty else { return }
        let y = yForCharOffset(offset)
        let maxY = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        let target = min(max(y, 0), maxY)
        scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        lastReportedOffset = offset
    }

    /// 字符偏移 → 该行顶部 y
    private func yForCharOffset(_ offset: Int) -> CGFloat {
        guard !lineStarts.isEmpty else { return 0 }
        let idx = lineStarts.lastIndex { $0 <= offset } ?? 0
        return lineTops[min(idx, lineTops.count - 1)]
    }

    /// 当前滚动位置 → 字符偏移（取视口顶部那一行）
    private func charOffsetAtCurrentScroll() -> Int {
        guard !lineTops.isEmpty else { return 0 }
        let y = scrollView.contentOffset.y
        if y <= 0 { return 0 }
        var lo = 0
        var hi = lineTops.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineTops[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return lineStarts[min(lo, lineStarts.count - 1)]
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reportOffset() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reportOffset()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        reportOffset()
    }

    private func reportOffset() {
        let offset = charOffsetAtCurrentScroll()
        if offset != lastReportedOffset {
            lastReportedOffset = offset
            onOffsetChange?(offset)
        }
        // 到底：自动进入下一章
        let maxY = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        if maxY > 0, scrollView.contentOffset.y >= maxY - 2 {
            onReachBottom?()
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let p = gesture.location(in: self)
        onTap?(p)
    }
}

extension ScrollableTextContainer: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - 测量辅助

enum TextMeasurer {
    /// 计算一段文本在指定宽度下的总高度（用于预估）
    static func height(of text: String, width: CGFloat, font: UIFont, lineSpacing: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let attributed = Paginator.makeAttributedString(text: text, font: font, lineSpacing: lineSpacing, color: .black)
        return height(of: attributed, width: width)
    }

    /// 计算 attributed string 在指定宽度下的总高度（连续滚动模式用）
    static func height(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard width > 0, attributed.length > 0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: attributed.length), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return ceil(size.height)
    }
}
