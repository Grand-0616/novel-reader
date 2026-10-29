//
//  ReaderFont.swift
//  阅读字体。iOS 自带一批中文字体，不用打包字体文件；
//  这里同时给出 family 名与 PostScript 名，逐个试，系统里没有的自动从列表里隐藏。
//

import UIKit

enum ReaderFont: String, CaseIterable, Identifiable {
    case system      = ""
    case songti      = "Songti SC"
    case kaiti       = "Kaiti SC"
    case yuanti      = "Yuanti SC"
    case heiti       = "Heiti SC"
    case fangsong    = "STFangsong"
    case xingkai     = "Xingkai SC"
    case baoli       = "Baoli SC"
    case lantinghei  = "Lantinghei SC"
    case hannotate   = "Hannotate SC"
    case hanzipen    = "Hanzipen SC"
    case weibei      = "Weibei SC"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:     return "系统"
        case .songti:     return "宋体"
        case .kaiti:      return "楷体"
        case .yuanti:     return "圆体"
        case .heiti:      return "黑体"
        case .fangsong:   return "仿宋"
        case .xingkai:    return "行楷"
        case .baoli:      return "报隶"
        case .lantinghei: return "兰亭黑"
        case .hannotate:  return "手札"
        case .hanzipen:   return "翩翩"
        case .weibei:     return "魏碑"
        }
    }

    /// family 名与 PostScript 名混着试，不同 iOS 版本注册的名字不一样
    private var aliases: [String] {
        switch self {
        case .system:     return []
        case .songti:     return ["Songti SC", "STSongti-SC-Regular", "STSong"]
        case .kaiti:      return ["Kaiti SC", "STKaiti-SC-Regular", "STKaiti"]
        case .yuanti:     return ["Yuanti SC", "STYuanti-SC-Regular", "STYuanti"]
        case .heiti:      return ["Heiti SC", "STHeitiSC-Medium", "STHeiti"]
        case .fangsong:   return ["STFangsong", "Fangsong"]
        case .xingkai:    return ["Xingkai SC", "STXingkai-SC-Light", "STXingkai"]
        case .baoli:      return ["Baoli SC", "STBaoli-SC-Regular", "STBaoli"]
        case .lantinghei: return ["Lantinghei SC", "STLantingheiSC-Extralight", "STLantinghei"]
        case .hannotate:  return ["Hannotate SC", "HannotateSC-W5"]
        case .hanzipen:   return ["Hanzipen SC", "HanzipenSC-Regular"]
        case .weibei:     return ["Weibei SC", "STWeibei-SC-Bold"]
        }
    }

    var resolvedName: String? {
        aliases.first { UIFont(name: $0, size: 17) != nil }
    }

    var isAvailable: Bool { self == .system || resolvedName != nil }

    static var available: [ReaderFont] { allCases.filter(\.isAvailable) }

    static func resolve(_ raw: String) -> ReaderFont { ReaderFont(rawValue: raw) ?? .system }

    func uiFont(size: CGFloat) -> UIFont {
        guard let name = resolvedName, let f = UIFont(name: name, size: size) else {
            return UIFont.systemFont(ofSize: size, weight: .regular)
        }
        return f
    }
}
