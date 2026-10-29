//
//  NovelReaderApp.swift
//  NovelReader
//
//  App 入口：SwiftData 容器、分享导入、全局外观
//

import SwiftUI
import SwiftData
import UIKit

@main
struct NovelReaderApp: App {
    @State private var appState = AppState()
    @State private var registry = SourceRegistry.shared
    @State private var legadoStore = LegadoStore()

    let container: ModelContainer

    init() {
        let schema = Schema([Book.self, Chapter.self])
        do {
            let config = ModelConfiguration("NovelReader", schema: schema)
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // 数据库损坏兜底：退回内存模式，避免启动即崩。
            // Books/ 里的原始文件和 ChapterCache/ 不受影响，用户可重新导入。
            NSLog("⚠️ SwiftData 持久化容器初始化失败，使用内存模式：\(error)")
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                container = try ModelContainer(for: schema, configurations: [config])
            } catch {
                // 连内存容器都建不起来说明模型定义有问题，这里明确报错而不是静默崩溃
                fatalError("SwiftData 模型配置无效：\(error)")
            }
        }
        _ = BookStorage.booksDirectory
        _ = BookStorage.inboxDirectory
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(registry)
                .environment(legadoStore)
                .modelContainer(container)
                .onOpenURL { url in
                    appState.handleIncomingURL(url)
                }
                .preferredColorScheme(appState.skin.colorScheme)
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry

    var body: some View {
        @Bindable var appState = appState

        TabView(selection: $appState.selectedTab) {
            LibraryView()
                .tabItem { Label("书架", systemImage: "books.vertical.fill") }
                .tag(AppState.Tab.library)

            AudiobookView()
                .tabItem { Label("有声", systemImage: "headphones") }
                .tag(AppState.Tab.audiobook)

            LegadoSourcesView()
                .tabItem { Label("书源", systemImage: "network") }
                .tag(AppState.Tab.sources)

            ComicView()
                .tabItem { Label("漫画", systemImage: "photo.on.rectangle.angled") }
                .tag(AppState.Tab.comic)

            DiscoverView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(AppState.Tab.discover)
        }
        .tint(appState.skin.accent)
        .environment(\.omniSkin, appState.skin)
        .onAppear {
            appState.attach(context: modelContext)
            Self.applyTabBarAppearance(appState.skin)
        }
        .onChange(of: appState.skin) { _, newSkin in
            Self.applyTabBarAppearance(newSkin)
        }
    }

    /// SwiftUI 的 TabView 底色跟随系统，云书阁那套深色金需要自己刷。
    private static func applyTabBarAppearance(_ skin: OmniSkin) {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(skin.surface)
        appearance.shadowColor = UIColor(skin.separator)

        let item = appearance.stackedLayoutAppearance
        item.selected.iconColor = UIColor(skin.accent)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(skin.accent)]
        item.normal.iconColor = UIColor(skin.textSecondary)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(skin.textSecondary)]

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
