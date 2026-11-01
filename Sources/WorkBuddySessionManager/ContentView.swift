import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var state = AppState()
    @State private var activeSheet: ActiveSheet?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            AccountSidebar(state: state)
                .navigationSplitViewColumnWidth(min: 216, ideal: 248)
        } content: {
            SessionList(state: state)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            SessionDetail(state: state)
        }
        .toolbar { toolbarContent }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .migrate:
                MigrateSheet(state: state, session: state.selectedSession)
            case .diskCleanup:
                DiskCleanupSheet(state: state)
            }
        }
        .alert(item: $state.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
        .confirmationDialog(
            "永久删除「\(state.pendingDeletion?.session.displayTitle ?? "")」？",
            isPresented: Binding(
                get: { state.pendingDeletion != nil },
                set: { if !$0 { state.pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) { state.confirmPermanentDelete() }
            Button("取消", role: .cancel) { state.pendingDeletion = nil }
        } message: {
            if let pending = state.pendingDeletion {
                Text(pending.size > 0
                     ? "正文 \(AppState.formatBytes(pending.size)) 会一起删掉，删了就没了，找不回来。"
                     : "这条记录会从索引里删掉，找不回来。")
            }
        }
        .task { state.bootstrap() }
        .frame(minWidth: 940, minHeight: 560)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Toggle(isOn: $state.showTrashed) {
                Label("显示回收站", systemImage: "trash")
            }
            .toggleStyle(.button)
            .hoverTip("回收站中的会话默认不显示")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if state.isBusy { ProgressView().controlSize(.small) }

            Button { state.killWorkBuddyProcesses() } label: {
                if state.isKilling {
                    ProgressView().controlSize(.small)
                } else {
                    Label("关闭 WorkBuddy", systemImage: "power")
                }
            }
            .disabled(state.isKilling)
            .hoverTip("结束 WorkBuddy 及其后台进程")

            Button { activeSheet = .migrate } label: { Label("迁移", systemImage: "arrow.left.arrow.right") }
                .disabled(state.selectedSession == nil)
                .hoverTip("把该会话的归属改到另一个账号")

            Button { exportSelected() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .disabled(state.selectedSession == nil)
                .hoverTip("导出为 markdown")

            if state.selectedSession?.isTrashed == true {
                Button { state.restore() } label: { Label("还原", systemImage: "arrow.uturn.backward") }
                    .hoverTip("从回收站还原")
                Button { state.requestPermanentDelete() } label: { Label("彻底删除", systemImage: "trash.slash") }
                    .disabled(state.selectedSession == nil)
                    .hoverTip("删掉正文，释放磁盘空间")
            } else {
                Button { state.requestPermanentDelete() } label: { Label("删除", systemImage: "trash") }
                    .disabled(state.selectedSession == nil)
                    .hoverTip("删掉正文，释放磁盘空间")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { activeSheet = .diskCleanup } label: {
                Label("磁盘清理", systemImage: "externaldrive.badge.timemachine")
            }
            .hoverTip("清理旧日志、追踪和缓存")
        }
    }

    private func exportSelected() {
        guard let session = state.selectedSession else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = TranscriptRenderer.exportFilename(for: session)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.title = "导出会话"
        panel.message = "选择 markdown 文件的保存位置"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let markdown = TranscriptRenderer.markdown(session: session, transcript: state.transcript)
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            state.statusLine = "已导出到 \(url.lastPathComponent)"
        } catch {
            state.alert = AppAlert(title: "导出失败", message: error.localizedDescription)
        }
    }
}

// MARK: - 侧栏

private struct AccountSidebar: View {
    @ObservedObject var state: AppState

    var body: some View {
        List(selection: $state.selectedUID) {
            Section("账号") {
                ForEach(state.accounts) { account in
                    AccountRow(account: account, isSelected: account.uid == state.selectedUID)
                        .tag(account.uid)
                        .contentShape(Rectangle())
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            SourceSwitcher(state: state)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.statusLine ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(state.source.directory.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(state.source.directory.path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

/// 两个官方发行版各用一套库，不明示当前在看哪一个就会把两边的账号混在一起。
private struct SourceSwitcher: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 9))
                    .foregroundStyle(.tint)
                Text("数据源")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !state.source.isInstalled {
                    Text("未安装")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            Picker("", selection: $state.source) {
                ForEach(DataSource.allCases) { option in
                    Text(option.appName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .hoverTip("两个发行版各用一套账号与会话库，互不相通")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct AccountRow: View {
    let account: Account
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(account.displayName)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                if account.isCurrent {
                    Text("当前")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.18), in: Capsule())
                }
            }
            Text("\(account.sessionCount) 个会话 · \(account.shortUID)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 会话列表

private struct SessionList: View {
    @ObservedObject var state: AppState

    var body: some View {
        List(selection: $state.selectedSessionID) {
            Section(header: Text(state.selectedAccount?.displayName ?? "未选择账号")) {
                ForEach(state.sessions) { session in
                    SessionRow(session: session).tag(session.id)
                }
            }
        }
        .overlay {
            if state.sessions.isEmpty {
                if state.isLoadingSessions {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        state.showTrashed ? "回收站是空的" : "没有会话",
                        systemImage: "tray",
                        description: Text(state.showTrashed ? "删除的会话会出现在这里" : "该账号下暂无会话")
                    )
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: WorkSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(session.displayTitle).lineLimit(1)
                if session.isCloudSynced {
                    Image(systemName: "icloud").font(.caption2).foregroundStyle(.secondary)
                }
                if session.isTrashed {
                    Image(systemName: "trash.fill").font(.caption2).foregroundStyle(.orange)
                }
            }
            HStack(spacing: 5) {
                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(session.shortID)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 详情

private struct SessionDetail: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if state.isLoadingSessions || state.isLoadingTranscript {
                ProgressView()
            } else if let session = state.selectedSession {
                detail(for: session)
            } else {
                ContentUnavailableView("选择一个会话", systemImage: "text.bubble")
            }
        }
    }

    private func detail(for session: WorkSession) -> some View {
        VStack(spacing: 0) {
            header(session)
            Divider()
            if state.transcript.isMissing {
                ContentUnavailableView(
                    "正文文件缺失",
                    systemImage: "doc.questionmark",
                    description: Text("索引里有这条记录，但对应的 jsonl 不在磁盘上。")
                )
            } else if state.transcript.turns.isEmpty {
                ContentUnavailableView("没有可显示的正文", systemImage: "text.alignleft")
            } else {
                transcriptList
            }
        }
    }

    private func header(_ session: WorkSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.displayTitle).font(.title3).fontWeight(.semibold)
            HStack(spacing: 8) {
                Label(session.shortID, systemImage: "number")
                Label(session.transport == "cloud" ? "云端同步" : "本地", systemImage: "externaldrive")
                Label("\(state.transcript.turns.count) 条消息", systemImage: "text.bubble")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !state.transcript.toolSummary.isEmpty {
                Text("工具：\(state.transcript.toolSummary)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Text(session.cwd)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(state.transcript.turns) { turn in
                    TurnView(turn: turn)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TurnView: View {
    let turn: Turn

    private var isUser: Bool { turn.speaker == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 64) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Text(isUser ? "用户" : "助手")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                MarkdownText(text: turn.text)
                    .multilineTextAlignment(.leading)
                    .padding(9)
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isUser ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                    }
            }
            if !isUser { Spacer(minLength: 64) }
        }
    }
}

private enum ActiveSheet: String, Identifiable {
    case migrate
    case diskCleanup

    var id: String { rawValue }
}

// MARK: - 磁盘清理

private struct DiskCleanupSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var retentionDays = 7
    @State private var selectedCategories: Set<DiskCleanupCategory> = [.logs, .sandboxLogs, .traces]
    @State private var showingConfirmation = false

    private var preview: DiskCleanupPreview? { state.diskCleanupPreview }
    private var selectedFiles: Int {
        preview?.files.filter { selectedCategories.contains($0.category) }.count ?? 0
    }
    private var selectedBytes: Int {
        preview?.files.filter { selectedCategories.contains($0.category) }.reduce(0) { $0 + $1.size } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("磁盘清理").font(.title2).fontWeight(.semibold)
                    Text("仅处理当前数据源：\(state.source.appName) · 版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(state.isCleaningDisk)
            }

            Text("删除超过所选期限的日志、追踪和缓存文件。会话正文、工作区、运行文件及数据库不会改动。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("保留最近")
                Picker("保留期限", selection: $retentionDays) {
                    ForEach(DiskCleanup.retentionOptions, id: \.self) { days in
                        Text("\(days) 天").tag(days)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .disabled(state.isScanningDisk || state.isCleaningDisk)
                .onChange(of: retentionDays) { _, value in state.scanDiskCleanup(retentionDays: value) }
                Spacer()
                Button("重新扫描") { state.scanDiskCleanup(retentionDays: retentionDays) }
                    .disabled(state.isScanningDisk || state.isCleaningDisk)
            }

            if state.isScanningDisk {
                ProgressView("正在统计可清理文件…")
                    .frame(maxWidth: .infinity, minHeight: 155)
            } else if let preview {
                VStack(spacing: 0) {
                    ForEach(preview.summaries) { item in
                        categoryRow(item)
                        if item.id != preview.summaries.last?.id { Divider() }
                    }
                    Divider()
                    HStack {
                        Text("已选 \(selectedFiles) 个文件")
                        Spacer()
                        Text(AppState.formatBytes(selectedBytes)).fontWeight(.semibold)
                    }
                    .font(.callout)
                    .padding(.vertical, 10)
                }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ContentUnavailableView(
                    "尚未扫描",
                    systemImage: "externaldrive",
                    description: Text(state.diskCleanupError ?? "扫描前会确认 WorkBuddy 已完全退出。")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            }

            if state.isCleaningDisk {
                ProgressView("正在逐项复核并清理…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = state.diskCleanupError, preview != nil {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let result = state.diskCleanupResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("清理完成：删除 \(result.deletedFiles) 个文件，释放 \(AppState.formatBytes(result.freedBytes))。")
                    if result.skippedChangedFiles > 0 {
                        Text("\(result.skippedChangedFiles) 个扫描后有变化的文件已跳过。")
                    }
                    if let stopReason = result.stopReason { Text(stopReason) }
                    ForEach(result.failures, id: \.self) { failure in Text(failure) }
                }
                .font(.caption)
                .foregroundColor(result.failures.isEmpty ? .secondary : .orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("清理前必须先退出 WorkBuddy。清理进行期间请勿重新打开它。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(state.isCleaningDisk)
                Button("清理所选文件…") { showingConfirmation = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview == nil || selectedCategories.isEmpty || selectedFiles == 0
                              || state.isScanningDisk || state.isCleaningDisk)
            }
        }
        .padding(20)
        .frame(width: 560)
        .confirmationDialog(
            "永久删除所选的 \(selectedFiles) 个文件？",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                state.cleanDisk(categories: selectedCategories)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("预计释放 \(AppState.formatBytes(selectedBytes))。日志、追踪和缓存会被永久删除，无法恢复。")
        }
        .onAppear { state.scanDiskCleanup(retentionDays: retentionDays) }
        .onChange(of: state.source) { _, _ in state.scanDiskCleanup(retentionDays: retentionDays) }
        .onDisappear {
            if !state.isCleaningDisk { state.cancelDiskCleanup() }
        }
        .interactiveDismissDisabled(state.isCleaningDisk)
    }

    private func categoryRow(_ item: DiskCleanupSummary) -> some View {
        let selected = Binding(
            get: { selectedCategories.contains(item.category) },
            set: { value in
                if value { selectedCategories.insert(item.category) }
                else { selectedCategories.remove(item.category) }
            }
        )
        return Toggle(isOn: selected) {
            HStack(spacing: 10) {
                Image(systemName: item.category.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(item.category.title)
                Spacer()
                Text("\(item.fileCount) 个 · \(AppState.formatBytes(item.bytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 9)
        .disabled(state.isCleaningDisk || item.fileCount == 0)
    }
}

// MARK: - 迁移面板

private struct MigrateSheet: View {
    @ObservedObject var state: AppState
    let session: WorkSession?
    @Environment(\.dismiss) private var dismiss
    @State private var targetUID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("迁移会话").font(.headline)

            if let session {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayTitle).fontWeight(.medium)
                    Text("当前归属  \(session.userID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("目标账号").font(.subheadline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(state.accounts) { account in
                    if account.uid != session?.userID {
                        Button {
                            targetUID = account.uid
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(account.displayName)
                                    Text("\(account.sessionCount) 个会话 · \(account.shortUID)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if targetUID == account.uid {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            }

            Text("只改索引里的归属，正文与工作目录保持原样，可随时改回。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("迁移") {
                    if let targetUID,
                       let target = state.accounts.first(where: { $0.uid == targetUID }) {
                        state.migrate(to: target)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(targetUID == nil)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            if let session {
                targetUID = state.accounts.first { $0.uid != session.userID }?.uid
            }
        }
    }
}
