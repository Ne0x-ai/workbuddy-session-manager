import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var state = AppState()
    @State private var showingMigrate = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            AccountSidebar(state: state)
                .navigationSplitViewColumnWidth(min: 216, ideal: 248)
        } content: {
            SessionList(state: state, showingMigrate: $showingMigrate)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            SessionDetail(state: state)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingMigrate) {
            MigrateSheet(state: state, session: state.selectedSession)
        }
        .alert(item: $state.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
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
            .help("回收站中的会话默认不显示")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if state.isBusy { ProgressView().controlSize(.small) }

            Button { showingMigrate = true } label: { Label("迁移", systemImage: "arrow.left.arrow.right") }
                .disabled(state.selectedSession == nil)
                .help("把该会话的归属改到另一个账号")

            Button { exportSelected() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .disabled(state.selectedSession == nil)
                .help("导出为 markdown")

            if state.selectedSession?.isTrashed == true {
                Button { state.restore() } label: { Label("还原", systemImage: "arrow.uturn.backward") }
                    .help("从回收站还原")
            } else {
                Button { state.moveToTrash() } label: { Label("删除", systemImage: "trash") }
                    .disabled(state.selectedSession == nil)
                    .help("移入回收站，正文不会删除，可随时还原")
            }
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
            .help("两个发行版各用一套账号与会话库，互不相通")
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
    @Binding var showingMigrate: Bool

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
