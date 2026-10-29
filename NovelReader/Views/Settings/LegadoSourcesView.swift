//
//  LegadoSourcesView.swift
//  NovelReader
//
//  Legado 书源管理界面：导入、分组、启停、查看规则。
//

import SwiftUI
import UniformTypeIdentifiers

struct LegadoSourcesView: View {

    /// 嵌进书架第四段时不要再套一层 NavigationStack，
    /// 否则会出现双层导航栏，标题也被压到第二行。
    var embedded: Bool = false

    @Environment(LegadoStore.self) private var store
    @Environment(SourceRegistry.self) private var registry
    @Environment(\.omniSkin) private var skin

    @State private var keyword = ""
    @State private var selectedGroup: String?
    @State private var showFileImporter = false
    @State private var showPasteSheet = false
    @State private var showURLSheet = false
    @State private var pasteText = ""
    @State private var remoteURL = ""
    @State private var alertMessage: String?
    @State private var showAlert = false
    @State private var exportURL: URL?
    @State private var pendingDelete: LegadoBookSource?

    private var filtered: [LegadoBookSource] {
        var list = store.sources(in: selectedGroup)
        let key = keyword.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            list = list.filter {
                $0.bookSourceName.localizedCaseInsensitiveContains(key)
                || $0.bookSourceUrl.localizedCaseInsensitiveContains(key)
                || ($0.bookSourceGroup ?? "").localizedCaseInsensitiveContains(key)
            }
        }
        return list
    }

    var body: some View {
        if embedded {
            coreBody
        } else {
            NavigationStack { coreBody }
        }
    }

    private var coreBody: some View {
        VStack(spacing: 0) {
            if embedded { embeddedBar }
            Group {
                if store.sources.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
        }
            .background(skin.background)
            .navigationTitle("书源")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(skin.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .searchable(text: $keyword, prompt: "搜索书源名称或地址")
            .toolbar { toolbarContent }
            .sheet(isPresented: $showPasteSheet) { pasteSheet }
            .sheet(isPresented: $showURLSheet) { urlSheet }
            .sheet(item: $remoteSheet) { target in
                switch target.mode {
                case .browse:
                    DiscoverView(initialSourceID: target.remote.id, showsClose: true)
                case .edit, .create:
                    NavigationStack {
                        SourceEditorView(source: target.remote,
                                         isNew: target.mode == .create)
                    }
                }
            }
            .sheet(isPresented: $showLegacySources) {
                SourcesView()
                    .environment(SourceRegistry.shared)
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.json, .plainText, .data],
                          allowsMultipleSelection: false) { result in
                handleFileImport(result)
            }
            .alert("提示", isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .confirmationDialog("删除书源",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let target = pendingDelete { store.remove(target) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text(pendingDelete?.bookSourceName ?? "")
            }
            .confirmationDialog("清空全部书源",
                                isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button("清空 \(store.sources.count) 个书源", role: .destructive) {
                    store.removeAll()
                    selectedGroup = nil
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不可撤销，导出的 JSON 备份仍可重新导入。")
            }
        }

    /// 内嵌时导航栏不可用，导入/导出入口改成页面顶部一行。
    private var embeddedBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(skin.textSecondary)
                TextField("搜索书源", text: $keyword)
                    .font(.system(size: 14))
                    .foregroundStyle(skin.textPrimary)
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(skin.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(skin.surfaceAlt)
            }

            Menu {
                Button {
                    showFileImporter = true
                } label: {
                    Label("导入 JSON 文件", systemImage: "doc.badge.plus")
                }
                Button {
                    showPasteSheet = true
                } label: {
                    Label("粘贴 JSON", systemImage: "doc.on.clipboard")
                }
                Button {
                    showURLSheet = true
                } label: {
                    Label("从网址导入", systemImage: "link")
                }
                Divider()
                Button {
                    remoteSheet = RemoteSheetTarget(
                        remote: RemoteSource.makeOPDS(name: "NAS OPDS 书库",
                                                      url: "http://192.168.1.100:8083/opds"),
                        mode: .create)
                } label: {
                    Label("添加 NAS / OPDS 源", systemImage: "externaldrive.connected.to.line.below")
                }
                if !store.sources.isEmpty {
                    Divider()
                    if let url = exportURL {
                        ShareLink(item: url) {
                            Label("导出书源", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("清空全部", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(skin.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - 列表

    private var listContent: some View {
        List {
            Section {
                summaryRow
                    .listRowBackground(skin.surface)
            }

            if !store.groups.isEmpty {
                Section {
                    groupChips
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowBackground(skin.surface)
                }
            }

            Section {
                ForEach(filtered) { source in
                    NavigationLink {
                        LegadoSourceDetailView(source: source)
                    } label: {
                        sourceRow(source)
                    }
                    .listRowBackground(skin.surface)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = source
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            store.toggleEnabled(source)
                        } label: {
                            Label(source.enabled ? "停用" : "启用",
                                  systemImage: source.enabled ? "pause.circle" : "play.circle")
                        }
                        .tint(source.enabled ? .orange : .green)
                    }
                }
            } header: {
                Text("Legado 书源 · \(filtered.count) 个")
            } footer: {
                Text("来自 Legado（阅读）生态，导入后可搜索、看目录、读正文。")
            }

            remoteSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(skin.background)
    }

    // MARK: - 网络源（NAS / OPDS / WebDAV / 规则站）

    /// 与 Legado 书源并列的第二类来源：局域网里的 NAS、OPDS 书库、
    /// WebDAV 目录、自定义规则站。它们不依赖 Legado 规则，走独立的连接层。
    private var remoteSection: some View {
        Section {
            if registry.sources.isEmpty {
                Text("还没有网络源。添加 NAS 的 OPDS 书库、HTTP 目录索引或 WebDAV 地址后，可以在这里浏览并导入书目。")
                    .font(.footnote)
                    .foregroundStyle(skin.textSecondary)
            } else {
                ForEach(registry.sources) { remote in
                    Button {
                        remoteSheet = RemoteSheetTarget(remote: remote, mode: .browse)
                    } label: {
                        remoteRow(remote)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(skin.surface)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            registry.remove(remote)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            remoteSheet = RemoteSheetTarget(remote: remote, mode: .edit)
                        } label: {
                            Label("编辑", systemImage: "slider.horizontal.3")
                        }
                        .tint(OmniPalette.gold)
                        Button {
                            Task { await checkRemote(remote) }
                        } label: {
                            Label("测试", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .tint(OmniPalette.blue)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            var copy = remote
                            copy.isEnabled.toggle()
                            registry.update(copy)
                        } label: {
                            Label(remote.isEnabled ? "停用" : "启用",
                                  systemImage: remote.isEnabled ? "pause.circle" : "play.circle")
                        }
                        .tint(remote.isEnabled ? .orange : .green)
                    }
                }
            }

            addRemoteMenu
                .listRowBackground(skin.surface)
        } header: {
            Text("网络源 · NAS / OPDS / WebDAV · \(registry.sources.count) 个")
        } footer: {
            Text("点一行直接浏览该源的书目目录；左滑可编辑地址、测试连通性。局域网直连，不需要外网。")
        }
    }

    private func remoteRow(_ remote: RemoteSource) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: remote.kind.symbolName)
                .font(.body)
                .foregroundStyle(remote.isEnabled ? skin.accent : skin.textSecondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(remote.name)
                        .font(.body)
                        .foregroundStyle(skin.textPrimary)
                        .lineLimit(1)
                    Text(remote.kind.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(skin.accent.opacity(0.16), in: Capsule())
                        .foregroundStyle(skin.accent)
                    if !remote.isEnabled {
                        Text("已停用")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(skin.surfaceAlt, in: Capsule())
                            .foregroundStyle(skin.textSecondary)
                    }
                }
                Text(remote.baseURL)
                    .font(.caption2)
                    .foregroundStyle(skin.textSecondary)
                    .lineLimit(1)
                if !remote.lastCheckMessage.isEmpty {
                    Text(remote.lastCheckMessage)
                        .font(.caption2)
                        .foregroundStyle(remote.lastCheckOK ? OmniPalette.success : OmniPalette.warning)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if checkingRemote == remote.id {
                ProgressView().scaleEffect(0.7)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(skin.textSecondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var addRemoteMenu: some View {
        Menu {
            Button {
                remoteSheet = RemoteSheetTarget(
                    remote: RemoteSource.makeOPDS(name: "NAS OPDS 书库",
                                                  url: "http://192.168.1.100:8083/opds"),
                    mode: .create)
            } label: {
                Label("OPDS 书库（calibre-web / Komga / Kavita）", systemImage: "books.vertical")
            }
            Button {
                remoteSheet = RemoteSheetTarget(
                    remote: RemoteSource.makeHTTPDir(name: "NAS HTTP 目录",
                                                     url: "http://192.168.1.100:8080/books/"),
                    mode: .create)
            } label: {
                Label("HTTP 目录索引", systemImage: "folder")
            }
            Button {
                remoteSheet = RemoteSheetTarget(
                    remote: RemoteSource.makeWebDAV(name: "NAS WebDAV",
                                                    url: "http://192.168.1.100:5005/books",
                                                    user: "", pass: ""),
                    mode: .create)
            } label: {
                Label("WebDAV（群晖 / 威联通）", systemImage: "network")
            }
            Button {
                var s = RemoteSource(name: "在线书源", kind: .rules, baseURL: "https://")
                s.isEnabled = true
                remoteSheet = RemoteSheetTarget(remote: s, mode: .create)
            } label: {
                Label("规则书源（自定义站点）", systemImage: "text.magnifyingglass")
            }
        } label: {
            Label("添加网络源", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(skin.accent)
        }
    }

    private func checkRemote(_ remote: RemoteSource) async {
        checkingRemote = remote.id
        defer { checkingRemote = nil }
        do {
            let msg = try await OPDSSource.ping(source: remote)
            registry.markCheck(remote.id, ok: true, message: msg)
            alertMessage = "\(remote.name)：\(msg)"
        } catch {
            registry.markCheck(remote.id, ok: false, message: error.localizedDescription)
            alertMessage = "\(remote.name)：\(error.localizedDescription)"
        }
        showAlert = true
    }

    private var summaryRow: some View {
        HStack(spacing: 16) {
            metric(value: "\(store.sources.count)", label: "全部")
            Divider().frame(height: 28)
            metric(value: "\(store.enabledSources.count)", label: "可用")
            Divider().frame(height: 28)
            metric(value: "\(store.sources.filter { !$0.readiness.isReady }.count)", label: "待修")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func metric(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(skin.textPrimary)
                .monospacedDigit()
            Text(label).font(.caption).foregroundStyle(skin.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", active: selectedGroup == nil) {
                    selectedGroup = nil
                }
                ForEach(store.groups, id: \.self) { group in
                    chip(title: group, active: selectedGroup == group) {
                        selectedGroup = selectedGroup == group ? nil : group
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(active ? skin.accent.opacity(0.18) : skin.surfaceAlt,
                            in: Capsule())
                .foregroundStyle(active ? skin.accent : skin.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private func sourceRow(_ source: LegadoBookSource) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: source.readiness.symbolName)
                .foregroundStyle(readinessColor(source.readiness))
                .font(.body)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.bookSourceName)
                        .font(.body)
                        .foregroundStyle(skin.textPrimary)
                        .lineLimit(1)
                    if !source.enabled {
                        Text("已停用")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(skin.surfaceAlt, in: Capsule())
                            .foregroundStyle(skin.textSecondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(source.type.displayName)
                        .font(.caption2)
                        .foregroundStyle(skin.textSecondary)
                    if let group = source.bookSourceGroup, !group.isEmpty {
                        Text("·").font(.caption2).foregroundStyle(skin.textSecondary)
                        Text(group)
                            .font(.caption2)
                            .foregroundStyle(skin.textSecondary)
                            .lineLimit(1)
                    }
                }
                if case .incomplete(let reason) = source.readiness {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(OmniPalette.warning)
                        .lineLimit(2)
                } else if case .invalid(let reason) = source.readiness {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(OmniPalette.danger)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func readinessColor(_ readiness: LegadoReadiness) -> Color {
        switch readiness {
        case .ready:      return OmniPalette.success
        case .incomplete: return OmniPalette.warning
        case .invalid:    return OmniPalette.danger
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 50)
                Image(systemName: "books.vertical")
                    .font(.system(size: 60, weight: .thin))
                    .foregroundStyle(skin.accent.opacity(0.75))
                Text("还没有书源")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(skin.textPrimary)
                Text("导入 Legado 格式的书源 JSON 后，就能搜索几百个站点。")
                    .font(.subheadline)
                    .foregroundStyle(skin.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)

                VStack(spacing: 12) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("导入 JSON 文件", systemImage: "doc.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(skin.background)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(skin.accent))
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 10) {
                        outlineButton("粘贴 JSON", "doc.on.clipboard") { showPasteSheet = true }
                        outlineButton("从网址导入", "link") { showURLSheet = true }
                    }
                }
                .padding(.horizontal, 36)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .background(skin.background)
    }

    private func outlineButton(_ title: String,
                               _ symbol: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .foregroundStyle(skin.accent)
                .padding(.vertical, 11)
                .background(Capsule().strokeBorder(skin.accent, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showFileImporter = true
                } label: {
                    Label("导入 JSON 文件", systemImage: "doc.badge.plus")
                }
                Button {
                    showPasteSheet = true
                } label: {
                    Label("粘贴 JSON", systemImage: "doc.on.clipboard")
                }
                Button {
                    showURLSheet = true
                } label: {
                    Label("从网址导入", systemImage: "link")
                }
                Divider()
                Button {
                    exportSources()
                } label: {
                    Label("导出书源", systemImage: "square.and.arrow.up")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("分享导出的文件", systemImage: "paperplane")
                    }
                }
                Divider()
                Button {
                    showLegacySources = true
                } label: {
                    Label("网络源完整管理页", systemImage: "externaldrive.connected.to.line.below")
                }
                Divider()
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("清空全部", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @State private var remoteSheet: RemoteSheetTarget?
    @State private var checkingRemote: UUID?

    @State private var showClearConfirm = false
    @State private var showLegacySources = false

    // MARK: - 导入面板

    private var pasteSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $pasteText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(skin.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .overlay(alignment: .topLeading) {
                        if pasteText.isEmpty {
                            Text("粘贴 Legado 书源 JSON（数组或单个对象）")
                                .font(.footnote)
                                .foregroundStyle(skin.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .background(skin.background)
            .navigationTitle("粘贴书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(skin.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showPasteSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        importPasted()
                    }
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var urlSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/sources.json", text: $remoteURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text("拉取远端 JSON 并合并进本地书源，相同地址会覆盖。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(skin.background)
            .navigationTitle("从网址导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(skin.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showURLSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { importRemote() }
                        .disabled(remoteURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - 动作

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let summary = try store.importFile(at: url)
                alertMessage = summary.description
            } catch {
                alertMessage = "导入失败：\(error.localizedDescription)"
            }
            showAlert = true
        case .failure(let error):
            alertMessage = "选择文件失败：\(error.localizedDescription)"
            showAlert = true
        }
    }

    private func importPasted() {
        let text = pasteText
        guard let data = text.data(using: .utf8) else { return }
        do {
            let summary = try store.importData(data)
            alertMessage = summary.description
            pasteText = ""
            showPasteSheet = false
        } catch {
            alertMessage = "导入失败：\(error.localizedDescription)"
        }
        showAlert = true
    }

    private func importRemote() {
        let target = remoteURL
        showURLSheet = false
        Task {
            do {
                let summary = try await store.importRemote(target)
                alertMessage = summary.description
            } catch {
                alertMessage = "导入失败：\(error.localizedDescription)"
            }
            showAlert = true
            remoteURL = ""
        }
    }

    private func exportSources() {
        do {
            exportURL = try store.exportToTemporaryFile()
            alertMessage = "已生成导出文件，可从菜单里的「分享导出的文件」保存。"
        } catch {
            alertMessage = "导出失败：\(error.localizedDescription)"
        }
        showAlert = true
    }
}

// MARK: - 书源详情

struct LegadoSourceDetailView: View {

    @Environment(LegadoStore.self) private var store
    @Environment(\.omniSkin) private var skin

    let source: LegadoBookSource

    private var current: LegadoBookSource {
        store.sources.first { $0.bookSourceUrl == source.bookSourceUrl } ?? source
    }

    var body: some View {
        List {
            Section("基本信息") {
                labeled("名称", current.bookSourceName)
                labeled("类型", current.type.displayName)
                labeled("分组", current.bookSourceGroup.flatMap { $0.isEmpty ? nil : $0 } ?? "未分组")
                labeled("地址", current.bookSourceUrl, mono: true)
                labeled("状态", current.readiness.label)
                if let comment = current.bookSourceComment, !comment.isEmpty {
                    labeled("备注", comment)
                }
            }
            .listRowBackground(skin.surface)

            Section("能力") {
                capability("搜索", ok: (current.ruleSearch?.isUsable ?? false))
                capability("发现", ok: (current.ruleExplore?.isUsable ?? false))
                capability("目录", ok: (current.ruleToc?.isUsable ?? false))
                capability("正文", ok: (current.ruleContent?.isUsable ?? false))
                capability("登录", ok: !(current.loginUrl ?? "").isEmpty)
                capability("脚本库", ok: !(current.jsLib ?? "").isEmpty)
            }
            .listRowBackground(skin.surface)

            if let searchURL = current.searchUrl, !searchURL.isEmpty {
                Section("搜索地址") {
                    Text(searchURL)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(skin.textSecondary)
                        .textSelection(.enabled)
                }
                .listRowBackground(skin.surface)
            }

            Section {
                Toggle("启用", isOn: Binding(
                    get: { current.enabled },
                    set: { newValue in
                        var copy = current
                        copy.enabled = newValue
                        store.update(copy)
                    }
                ))
                .tint(skin.accent)
            }
            .listRowBackground(skin.surface)
        }
        .scrollContentBackground(.hidden)
        .background(skin.background)
        .navigationTitle(current.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(skin.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func labeled(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(skin.textSecondary)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "—" : value)
                .foregroundStyle(skin.textPrimary)
                .multilineTextAlignment(.trailing)
                .font(mono ? .system(.footnote, design: .monospaced) : .footnote)
                .textSelection(.enabled)
        }
    }

    private func capability(_ title: String, ok: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(skin.textPrimary)
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(ok ? OmniPalette.success : skin.textSecondary)
        }
    }
}

// MARK: - 网络源弹窗目标

/// 网络源这一栏既要点进去浏览，又要能进编辑页。
/// 用一个 sheet 承载两种用途，避免同视图挂两个 sheet(item:) 时只有最后一个生效。
struct RemoteSheetTarget: Identifiable {

    enum Mode {
        case browse
        case edit
        case create
    }

    let remote: RemoteSource
    let mode: Mode

    var id: String { "\(mode)-\(remote.id.uuidString)" }
}
