//
//  AudiobookView.swift
//  NovelReader
//
//  有声书 Tab：列出书库里的音频文件，为后续接入播放器留出入口。
//

import SwiftUI
import SwiftData

struct AudiobookView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.omniSkin) private var skin

    @Query(sort: [SortDescriptor(\Book.lastOpenedAt, order: .reverse),
                  SortDescriptor(\Book.createdAt, order: .reverse)])
    private var books: [Book]

    @State private var pendingNotice: String?

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg", "opus"
    ]

    private var tracks: [Book] {
        books.filter { Self.audioExtensions.contains($0.fileFormat.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if tracks.isEmpty {
                    OmniEmptyState(
                        symbol: "headphones",
                        title: "还没有有声书",
                        message: "把 mp3 / m4a / m4b 放进「文件」App 的 NovelReader 目录，或从分享菜单导入。",
                        actionTitle: "去书架导入"
                    ) {
                        appState.selectedTab = .library
                    }
                } else {
                    trackList
                }
            }
            .navigationTitle("有声")
            .background(skin.background)
            .toolbarBackground(skin.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .alert("播放器还没接上", isPresented: Binding(
                get: { pendingNotice != nil },
                set: { if !$0 { pendingNotice = nil } }
            )) {
                Button("知道了", role: .cancel) { pendingNotice = nil }
            } message: {
                Text(pendingNotice ?? "")
            }
        }
    }

    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(tracks) { book in
                    Button {
                        pendingNotice = "「\(book.title)」的播放界面还没做。下一步接 AVSpeechSynthesizer 朗读和音频播放。"
                    } label: {
                        trackRow(book)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(skin.background)
    }

    private func trackRow(_ book: Book) -> some View {
        HStack(spacing: 12) {
            OmniBookCard(
                title: book.title,
                author: book.author,
                coverData: book.coverData,
                progress: nil
            )
            .frame(width: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(skin.textPrimary)
                    .lineLimit(1)
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.caption)
                    .foregroundStyle(skin.textSecondary)
                    .lineLimit(1)
                Text(book.fileFormat.uppercased())
                    .font(.caption2)
                    .foregroundStyle(skin.accent)
            }

            Spacer(minLength: 8)

            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(skin.accent)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(skin.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(skin.separator, lineWidth: 1)
        )
    }
}
