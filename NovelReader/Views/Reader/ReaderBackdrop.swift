//
//  ReaderBackdrop.swift
//  NovelReader
//
//  阅读页氛围背景：程序化绘制，不依赖图片资源。
//  云书阁的阅读背景是整幅山水/星空插画，这里用渐变 + 剪影 + 粒子近似，
//  保证静态绘制一次即可，不参与翻页重绘。
//

import SwiftUI

enum ReaderBackdrop: String, CaseIterable, Identifiable, Codable {
    case none
    case starry
    case mountains
    case parchment
    case mist
    case dusk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "纯色"
        case .starry: return "星空"
        case .mountains: return "远山"
        case .parchment: return "纸纹"
        case .mist: return "云雾"
        case .dusk: return "暮色"
        }
    }

    /// 背景偏暗时，正文该用浅色字
    var prefersLightText: Bool {
        switch self {
        case .starry, .mist, .dusk: return true
        case .none, .mountains, .parchment: return false
        }
    }
}

struct ReaderBackdropView: View {
    let style: ReaderBackdrop
    let theme: ReaderTheme

    var body: some View {
        ZStack {
            base
            switch style {
            case .none:
                EmptyView()
            case .starry:
                StarryLayer()
            case .mountains:
                MountainLayer(dark: false)
            case .parchment:
                ParchmentLayer()
            case .mist:
                MountainLayer(dark: true)
            case .dusk:
                DuskLayer()
            }
        }
        .allowsHitTesting(false)
        // 粒子与渐变在每次 body 求值时都会重画；离屏合成成一张纹理后，
        // 工具栏显隐、页码变化都不再触发底层重绘。
        .drawingGroup(opaque: false)
    }

    @ViewBuilder
    private var base: some View {
        switch style {
        case .none:
            theme.backgroundColor
        case .starry:
            LinearGradient(
                colors: [Color(hex: 0x0A1020), Color(hex: 0x16203A), Color(hex: 0x080D18)],
                startPoint: .top, endPoint: .bottom)
        case .mountains:
            LinearGradient(
                colors: [Color(hex: 0xF7F2E7), Color(hex: 0xEDE4D2), Color(hex: 0xDFD2BA)],
                startPoint: .top, endPoint: .bottom)
        case .parchment:
            LinearGradient(
                colors: [Color(hex: 0xF4EAD3), Color(hex: 0xEDDFC2), Color(hex: 0xE6D5B4)],
                startPoint: .top, endPoint: .bottom)
        case .mist:
            LinearGradient(
                colors: [Color(hex: 0x0D1316), Color(hex: 0x1B2A2C), Color(hex: 0x090E10)],
                startPoint: .top, endPoint: .bottom)
        case .dusk:
            LinearGradient(
                colors: [Color(hex: 0x1B1526), Color(hex: 0x3B2436), Color(hex: 0x110D17)],
                startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: - 确定性随机（背景粒子每次一致，不闪烁）

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 16
    }

    mutating func unit() -> Double {
        Double(next() % 10_000) / 10_000.0
    }
}

// MARK: - 星空

private struct StarryLayer: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Canvas { ctx, size in
                var rng = SeededRandom(seed: 20_261_029)
                for _ in 0..<170 {
                    let x = CGFloat(rng.unit()) * size.width
                    let y = CGFloat(rng.unit()) * size.height * 0.78
                    let r = CGFloat(rng.unit()) * 1.3 + 0.5
                    let a = rng.unit() * 0.55 + 0.18
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                        with: .color(.white.opacity(a)))
                }
            }

            // 月亮 + 光晕
            let m = CGRect(x: w * 0.70, y: h * 0.055, width: 52, height: 52)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0xFFF8E4).opacity(0.30), .clear],
                        center: .center, startRadius: 2, endRadius: 96)
                )
                .frame(width: 192, height: 192)
                .position(x: m.midX, y: m.midY)
            Circle()
                .fill(Color(hex: 0xFFF9E8).opacity(0.9))
                .frame(width: m.width, height: m.height)
                .position(x: m.midX, y: m.midY)
            // 月面阴影
            Circle()
                .fill(Color(hex: 0xE4D8B4).opacity(0.35))
                .frame(width: 14, height: 14)
                .position(x: m.midX + 12, y: m.midY - 10)

            // 底部山脊剪影
            Path { p in
                p.move(to: CGPoint(x: 0, y: h * 0.86))
                p.addCurve(
                    to: CGPoint(x: w * 0.42, y: h * 0.78),
                    control1: CGPoint(x: w * 0.14, y: h * 0.72),
                    control2: CGPoint(x: w * 0.28, y: h * 0.84))
                p.addCurve(
                    to: CGPoint(x: w * 0.78, y: h * 0.84),
                    control1: CGPoint(x: w * 0.58, y: h * 0.70),
                    control2: CGPoint(x: w * 0.68, y: h * 0.90))
                p.addCurve(
                    to: CGPoint(x: w, y: h * 0.80),
                    control1: CGPoint(x: w * 0.88, y: h * 0.78),
                    control2: CGPoint(x: w * 0.94, y: h * 0.86))
                p.addLine(to: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: 0, y: h))
                p.closeSubpath()
            }
            .fill(Color(hex: 0x060A12).opacity(0.85))
        }
    }
}

// MARK: - 远山 / 云雾

private struct MountainLayer: View {
    let dark: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let baseY = h * (0.50 + Double(i) * 0.11)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: baseY))
                        p.addCurve(
                            to: CGPoint(x: w * 0.36, y: baseY - h * 0.09),
                            control1: CGPoint(x: w * 0.12, y: baseY - h * 0.14),
                            control2: CGPoint(x: w * 0.24, y: baseY - h * 0.01))
                        p.addCurve(
                            to: CGPoint(x: w * 0.70, y: baseY - h * 0.05),
                            control1: CGPoint(x: w * 0.50, y: baseY - h * 0.15),
                            control2: CGPoint(x: w * 0.60, y: baseY + h * 0.02))
                        p.addCurve(
                            to: CGPoint(x: w, y: baseY - h * 0.11),
                            control1: CGPoint(x: w * 0.86, y: baseY - h * 0.09),
                            control2: CGPoint(x: w * 0.94, y: baseY - h * 0.15))
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.addLine(to: CGPoint(x: 0, y: h))
                        p.closeSubpath()
                    }
                    .fill(
                        dark
                        ? Color(hex: 0x08100F).opacity(0.50 - Double(i) * 0.11)
                        : Color(hex: 0x7E8C7C).opacity(0.13 + Double(i) * 0.07))
                }

                // 顶部薄雾
                LinearGradient(
                    colors: [Color.white.opacity(dark ? 0.05 : 0.35), .clear],
                    startPoint: .top, endPoint: .center)
            }
        }
    }
}

// MARK: - 纸纹

private struct ParchmentLayer: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Canvas { ctx, size in
                    var rng = SeededRandom(seed: 77_123)
                    for _ in 0..<520 {
                        let x = CGFloat(rng.unit()) * size.width
                        let y = CGFloat(rng.unit()) * size.height
                        let r = CGFloat(rng.unit()) * 2.4 + 0.7
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                            with: .color(Color(hex: 0xA88A5C).opacity(0.055)))
                    }
                }

                // 暗角
                RadialGradient(
                    colors: [.clear, Color(hex: 0x8A6B3A).opacity(0.16)],
                    center: .center,
                    startRadius: w * 0.30,
                    endRadius: max(w, h) * 0.78)

                // 纵向纸纤维
                Canvas { ctx, size in
                    var rng = SeededRandom(seed: 4_401)
                    for _ in 0..<26 {
                        let x = CGFloat(rng.unit()) * size.width
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x + CGFloat(rng.unit()) * 6 - 3, y: size.height))
                        ctx.stroke(p, with: .color(Color(hex: 0xB09264).opacity(0.045)), lineWidth: 0.7)
                    }
                }
            }
        }
    }
}

// MARK: - 暮色

private struct DuskLayer: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // 地平线暖光
                RadialGradient(
                    colors: [Color(hex: 0xC9773F).opacity(0.28), .clear],
                    center: UnitPoint(x: 0.5, y: 1.05),
                    startRadius: 8,
                    endRadius: h * 0.55)

                // 远山
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.72))
                    p.addCurve(
                        to: CGPoint(x: w * 0.48, y: h * 0.66),
                        control1: CGPoint(x: w * 0.18, y: h * 0.62),
                        control2: CGPoint(x: w * 0.32, y: h * 0.74))
                    p.addCurve(
                        to: CGPoint(x: w, y: h * 0.70),
                        control1: CGPoint(x: w * 0.72, y: h * 0.58),
                        control2: CGPoint(x: w * 0.86, y: h * 0.76))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(Color(hex: 0x0D0A12).opacity(0.72))
            }
        }
    }
}
