//
//  ReaderSettingsView.swift
//  NovelReader
//
//  排版设置的入口封装 + 实时预览卡片
//

import SwiftUI

struct ReaderSettingsView: View {
    var body: some View {
        ReaderSettingsPanel(asSheet: false)
    }
}

/// 排版实时预览（在设置页展示一段示例）
struct TypographyPreviewCard: View {
    @Environment(AppState.self) private var appState

    private let sample = """
    　　青石板路一直延伸到山门之外，两侧的古松在风里发出细碎的响声。
    　　他站在台阶最下面，抬头看着那块被风雨磨得发白的匾额，忽然想起许多年前的一个傍晚。
    　　那时他还不知道，这条路会走这么久。
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(sample)
                .font(.system(size: appState.fontSize * 0.8))
                .lineSpacing(appState.lineSpacing * 0.8)
                .foregroundStyle(appState.theme.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(appState.theme.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }
}
