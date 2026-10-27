//
//  SourcesView.swift
//  NovelReader
//
//  书源管理：NAS(OPDS/HTTP/WebDAV) 与规则书源的新增、编辑、测试、导入导出
//

import SwiftUI

struct SourcesView: View {
    @Environment(SourceRegistry.self) private var registry

    @State private var editing: RemoteSource?
    @State private var showEditor = false
    @State private var showImport = false
    @State private var showExport = false
    @State private var checkStates: [UUID: Bool] = [:]
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(registry.sources) { source in
                        Button {
                            editing = source
                            showEditor = true
                        } label: {
                            row(source)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                registry.remove(source)
                            } label: { Label("删除", systemImage: "trash") }

                            Button {
                                Task { await test(source) }
                            } label: { Label("测试", systemImage: "antenna.radiowaves.left.and.right") }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("已配置书源")
                } footer: {
                    Text("左滑可删除或测试连通性。点击进入编辑。")
                }

                Section("添加") {
                    Menu {
                        Button {
                            editing = RemoteSource.makeOPDS(name: "NAS OPDS 书库", url: "http://192.168.1.100:8083/opds")
                            showEditor = true
                        } label: { Label("OPDS 书库（calibre-web / COPS / Komga / Kavita）", systemImage: "books.vertical") }

                        Button {
                            editing = RemoteSource.makeHTTPDir(name: "NAS HTTP 目录", url: "http://192.168.1.100:8080/books/")
                            showEditor = true
                        } label: { Label("HTTP 目录索引", systemImage: "folder") }

                        Button {
                            editing = RemoteSource.makeWebDAV(name: "NAS WebDAV", url: "http://192.168.1.100:5005/books",
                                                              user: "", pass: "")
                            showEditor = true
                        } label: { Label("WebDAV（群晖/威联通）", systemImage: "network") }

                        Button {
                            var s = RemoteSource(name: "在线书源", kind: .rules, baseURL: "https://")
                            s.isEnabled = true
                            editing = s
                            showEditor = true
                        } label: { Label("规则书源（自定义站点）", systemImage: "text.magnifyingglass") }
                    } label: {
                        Label("新增书源", systemImage: "plus.circle.fill")
                    }

                    Button { showImport = true } label: {
                        Label("从 JSON 导入书源", systemImage: "doc.badge.plus")
                    }
                    Button { showExport = true } label: {
                        Label("导出书源配置", systemImage: "square.and.arrow.up")
                    }
                }

                Section("NAS 接入提示") {
                    VStack(alignment: .leading, spacing: 8) {
                        tip("calibre-web", "设置 → 功能 → 启用 OPDS 源，地址一般是 http://NAS:8083/opds")
                        tip("COPS", "部署后访问 http://NAS/cops/opds")
                        tip("Komga", "http://NAS:25600/opds/v1.2/catalog")
                        tip("Kavita", "http://NAS:5000/api/opds（需在设置里生成 API Key）")
                        tip("群晖 WebDAV", "套件中心装 WebDAV Server，端口 5005，路径 /books")
                        tip("nginx 目录", "开启 autoindex on; 后填 http://NAS/books/")
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("书源")
            .sheet(item: $editing) { source in
                SourceEditorView(source: source, isNew: !registry.sources.contains(where: { $0.id == source.id }))
            }
            .sheet(isPresented: $showImport) {
                NavigationStack { SourceImportView() }
            }
            .sheet(isPresented: $showExport) {
                NavigationStack {
                    ScrollView {
                        Text(registry.exportJSON())
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                    }
                    .navigationTitle("书源配置 JSON")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        Button("复制") {
                            UIPasteboard.general.string = registry.exportJSON()
                            message = "已复制到剪贴板"
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                if let message {
                    ImportBanner(message: message).padding(.top, 6)
                }
            }
        }
    }

    private func row(_ source: RemoteSource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.kind.symbolName)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(source.isEnabled ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.name).font(.subheadline.weight(.medium))
                    if !source.isEnabled {
                        Text("已停用")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(source.baseURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !source.lastCheckMessage.isEmpty {
                    Text(source.lastCheckMessage)
                        .font(.caption2)
                        .foregroundStyle(source.lastCheckOK ? .green : .orange)
                        .lineLimit(1)
                }
            }
            Spacer()
            if checkStates[source.id] == true {
                ProgressView().scaleEffect(0.7)
            } else {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func tip(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func test(_ source: RemoteSource) async {
        checkStates[source.id] = true
        defer { checkStates[source.id] = false }
        do {
            let msg = try await OPDSSource.ping(source: source)
            registry.markCheck(source.id, ok: true, message: msg)
            message = "\(source.name)：\(msg)"
        } catch {
            if source.kind == .rules || source.kind == .jsonAPI {
                registry.markCheck(source.id, ok: true, message: "规则书源，请在发现页搜索测试")
                message = "\(source.name)：请在发现页搜索验证"
            } else {
                registry.markCheck(source.id, ok: false, message: error.localizedDescription)
                message = "\(source.name)：\(error.localizedDescription)"
            }
        }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        message = nil
    }
}

// MARK: - 书源编辑

struct SourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SourceRegistry.self) private var registry

    @State var source: RemoteSource
    let isNew: Bool

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("名称", text: $source.name)
                Picker("类型", selection: $source.kind) {
                    ForEach(SourceKind.allCases, id: \.self) { k in
                        Text(k.displayName).tag(k)
                    }
                }
                TextField("地址", text: $source.baseURL, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(1...3)
                Toggle("启用", isOn: $source.isEnabled)
            }

            Section("认证（可选）") {
                TextField("用户名", text: $source.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $source.password)
            }

            if source.kind == .rules || source.kind == .jsonAPI {
                ruleSections
            }

            Section("高级") {
                TextField("User-Agent", text: $source.userAgent, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                TextField("编码（utf-8 / gbk）", text: $source.encoding)
                    .textInputAutocapitalization(.never)
            }

            Section {
                Button(isNew ? "添加" : "保存") {
                    if let normalized = HTTPClient.normalizeBase(source.baseURL) {
                        source.baseURL = normalized
                    }
                    if isNew {
                        registry.add(source)
                    } else {
                        registry.update(source)
                    }
                    dismiss()
                }
                .disabled(source.name.isEmpty || source.baseURL.isEmpty)

                if !isNew {
                    Button("删除此书源", role: .destructive) {
                        registry.remove(source)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "新增书源" : "编辑书源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var ruleSections: some View {
        if source.kind == .rules {
            Section {
                TextField("{keyword} {page} 占位", text: $source.searchURLTemplate, axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...3)
                field("列表项选择器", $source.searchItemSelector)
                field("标题", $source.searchTitleSelector)
                field("链接（可带 @href）", $source.searchLinkSelector)
                field("作者", $source.searchAuthorSelector)
                field("封面", $source.searchCoverSelector)
            } header: { Text("搜索规则") }

            Section {
                field("书名", $source.detailTitleSelector)
                field("作者", $source.detailAuthorSelector)
                field("封面", $source.detailCoverSelector)
                field("简介", $source.detailSummarySelector)
                field("章节链接", $source.detailChapterSelector)
                field("章节标题", $source.detailChapterTitleSelector)
            } header: { Text("详情/目录规则") }

            Section {
                field("正文容器", $source.contentSelector)
                TextField("要去掉的元素，逗号分隔", text: Binding(
                    get: { source.contentRemoveSelectors.joined(separator: ",") },
                    set: { source.contentRemoveSelectors = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ), axis: .vertical)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1...3)
            } header: { Text("正文规则") } footer: {
                Text("支持 CSS：div#content、div.content p、a@href；也支持简化 XPath：//div[@id='list']//a")
                    .font(.caption2)
            }
        } else {
            Section("JSON API") {
                field("搜索地址模板", $source.searchURLTemplate)
                field("结果数组路径", $source.jsonSearchPath)
                field("标题字段", $source.jsonTitleField)
                field("作者字段", $source.jsonAuthorField)
                field("链接字段", $source.jsonLinkField)
                field("封面字段", $source.jsonCoverField)
                field("章节数组路径", $source.jsonChapterPath)
                field("章节标题字段", $source.jsonChapterTitleField)
                field("章节链接字段", $source.jsonChapterLinkField)
                field("正文字段", $source.jsonContentField)
            }
        }
    }

    private func field(_ title: String, _ binding: Binding<String>) -> some View {
        TextField(title, text: binding)
            .font(.system(.caption, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

// MARK: - 书源导入

struct SourceImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SourceRegistry.self) private var registry

    @State private var text = ""
    @State private var errorMessage: String?
    @State private var message: String?

    var body: some View {
        Form {
            Section("粘贴 JSON") {
                TextEditor(text: $text)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(minHeight: 200)
            }
            Section {
                Button("从剪贴板读取") {
                    if let s = UIPasteboard.general.string { text = s }
                }
                Button("导入") {
                    do {
                        let count = try registry.importJSON(text)
                        message = "已导入 \(count) 个书源"
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .disabled(text.isEmpty)
            }
        }
        .navigationTitle("导入书源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .alert("导入失败", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
