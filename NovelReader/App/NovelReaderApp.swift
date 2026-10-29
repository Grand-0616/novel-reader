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
    @State private var showSearch = false

    var body: some View {
        @Bindable var appState = appState
        let skin = appState.skin

        Group {
            switch appState.selectedTab {
            case .library:  LibraryView()
            case .settings: SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OmniTabBar(selection: $appState.selectedTab, skin: skin) {
                showSearch = true
            }
        }
        .sheet(isPresented: $showSearch) {
            DiscoverView(showsClose: true)
        }
        .tint(skin.accent)
        .environment(\.omniSkin, skin)
        .onAppear { appState.attach(context: modelContext) }
    }
}
