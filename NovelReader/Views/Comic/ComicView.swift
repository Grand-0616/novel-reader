//
//  ComicView.swift
//  NovelReader
//
//  漫画 Tab：列出书库里的图片包（cbz / cbr / zip 等）。
//

import SwiftUI
import SwiftData

struct ComicView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.omniSkin) private var skin

    @Query(sort: [SortDescriptor(\Book.lastOpenedAt, order: .reverse),
                  SortDescriptor(\Book.createdAt, order: .reverse)])
    private var books: [Book]

    @State private var pendingNotice: String?

    private static let comicExtensions: Set<String> = [
        "cbz", "cbr", "cb7", "cbt", "zip", "rar", "7z", "tar"
    ]

    private var comics: [Book] {
        books.filter { Self.comicExtensions.contains($0.fileFormat.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if comics.isEmpty {
                    OmniEmptyState(
                        symbol: "photo.on.rectangle.angled",
                        title: "还没有漫画",
                        message: "把 cbz / cbr / zip 图片包放进「文件」App 的 NovelReader 目录，或从分享菜单导入。",
                        actionTitle: "去书架导入"
                    ) {
                        appState.selectedTab = .library
                    }
                } else {
                    comicGrid
                }
            }
            .navigationTitle("漫画")
            .background(skin.background)
            .toolbarBackground(skin.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .alert("阅读器还没接上", isPresented: Binding(
                get: { pendingNotice != nil },
                set: { if !$0 { pendingNotice = nil } }
            )) {
                Button("知道了", role: .cancel) { pendingNotice = nil }
            } message: {
                Text(pendingNotice ?? "")
            }
        }
    }

    private var comicGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 14)], spacing: 18) {
                ForEach(comics) { book in
                    Button {
                        pendingNotice = "「\(book.title)」的图片阅读器还没做。下一步接分页图片浏览。"
                    } label: {
                        OmniBookCard(
                            title: book.title,
                            author: book.author,
                            coverData: book.coverData,
                            progress: nil,
                            badge: book.fileFormat.uppercased()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(skin.background)
    }
}
