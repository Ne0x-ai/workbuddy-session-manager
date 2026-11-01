import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var sessions: [WorkSession] = []
    @Published var selectedUID: String? {
        didSet { if selectedUID != oldValue { loadSessions() } }
    }
    @Published var selectedSessionID: String? {
        didSet { if selectedSessionID != oldValue { loadTranscript() } }
    }
    @Published var showTrashed = false { didSet { loadSessions() } }
    @Published var transcript = Transcript()
    @Published var alert: AppAlert?
    @Published var statusLine: String?
    @Published var isBusy = false
    @Published var isKilling = false
    /// 待确认的永久删除。不可逆，得先跟用户把账算清楚。
    @Published var pendingDeletion: PendingDeletion?
    @Published var isLoadingSessions = false
    @Published var isLoadingTranscript = false
    @Published var diskCleanupPreview: DiskCleanupPreview?
    @Published var diskCleanupResult: DiskCleanupResult?
    @Published var diskCleanupError: String?
    @Published var isScanningDisk = false
    @Published var isCleaningDisk = false

    private var diskCleanupToken = 0
    private var diskCleanupTask: Task<Void, Never>?
    private var diskCleanupCancellation: DiskCleanupCancellation?

    /// 两个发行版各用一套库，切换就是换整个数据目录。
    @Published var source: DataSource = .overseas {
        didSet {
            if source != oldValue {
                cancelDiskCleanup()
                bootstrap()
            }
        }
    }

    /// 展示时按 UID 前缀模糊匹配选中项，切号后不至于高亮丢失。
    private var db: Database?

    /// 快速连点时，先发起的加载可能后返回。按资源分别计数，回来过期的直接丢掉。
    private var tokens: [String: Int] = [:]

    var selectedAccount: Account? {
        accounts.first { $0.uid == selectedUID }
    }

    var selectedSession: WorkSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var totalTrashed: Int {
        accounts.reduce(0) { $0 + $1.trashedCount }
    }

    private func nextToken(_ key: String) -> Int {
        tokens[key, default: 0] += 1
        return tokens[key, default: 0]
    }

    private func isCurrent(_ key: String, _ token: Int) -> Bool {
        tokens[key] == token
    }

    // MARK: - 加载

    func bootstrap() {
        // 两个发行版的 uid 空间完全独立，旧选择带过去只会选错行。
        accounts = []
        sessions = []
        transcript = Transcript()
        selectedUID = nil
        selectedSessionID = nil
        db = nil

        guard source.isInstalled else {
            statusLine = "未检测到 \(source.appName)，请先安装并至少启动过一次"
            return
        }
        isLoadingSessions = true
        let token = nextToken("accounts")
        let dir = source.directory
        Task {
            do {
                let list = try await Task.detached(priority: .userInitiated) {
                    try Database.accounts(at: dir)
                }.value
                guard isCurrent("accounts", token) else { return }
                db = try? Database(dataDir: dir)
                accounts = list
                statusLine = appStatusLine()
                // 默认落在当前登录的账号上，而不是会话最多的那个
                selectedUID = list.first { $0.isCurrent }?.uid ?? list.first?.uid
                if selectedUID == nil { isLoadingSessions = false }
            } catch {
                guard isCurrent("accounts", token) else { return }
                isLoadingSessions = false
                alert = AppAlert(title: "无法读取数据", message: error.localizedDescription)
            }
        }
    }

    private func loadSessions() {
        sessions = []
        selectedSessionID = nil
        guard db != nil, let uid = selectedUID else {
            transcript = Transcript()
            isLoadingSessions = false
            return
        }
        let dir = source.directory
        let trashed = showTrashed
        let token = nextToken("sessions")
        isLoadingSessions = true
        Task {
            do {
                let list = try await Task.detached(priority: .userInitiated) {
                    try Database.sessions(at: dir, userID: uid, includeTrashed: trashed)
                }.value
                guard isCurrent("sessions", token), isCurrent("accounts", tokens["accounts"] ?? 0) else { return }
                sessions = list
                isLoadingSessions = false
                selectedSessionID = list.first?.id
            } catch {
                guard isCurrent("sessions", token) else { return }
                isLoadingSessions = false
                alert = AppAlert(title: "读取失败", message: error.localizedDescription)
            }
        }
    }

    /// jsonl 解析是唯一称得上重的一步——一个会话能有几百条对话、上兆字符，
    /// 放主线程上点一下会话就顿住。
    private func loadTranscript() {
        guard let session = selectedSession else {
            transcript = Transcript()
            isLoadingTranscript = false
            return
        }
        let dir = source.directory
        let token = nextToken("transcript")
        isLoadingTranscript = true
        Task {
            let parsed = await Task.detached(priority: .userInitiated) {
                Database.transcript(at: dir, session: session)
            }.value
            guard isCurrent("transcript", token), selectedSessionID == session.id else { return }
            transcript = parsed
            isLoadingTranscript = false
        }
    }

    /// 写操作之后回到一致状态，路径与首屏加载相同。
    func reload() {
        loadSessions()
    }

    func appStatusLine() -> String {
        let pids = Database.runningProcessIDs()
        return pids.isEmpty
            ? "\(source.appName) 未运行，可安全编辑"
            : "\(source.appName) 运行中（\(pids.count) 个进程），编辑操作会被拦截"
    }

    // MARK: - 进程

    /// 结束 WorkBuddy 及其后台进程。
    ///
    /// Command+Q 只退 GUI，sidecar 会以 detached 方式活下来，父进程被 init 收养，
    /// 没有哪个 app 认领它。写库前必须先把它清掉。
    func killWorkBuddyProcesses() {
        guard !isKilling else { return }
        isKilling = true
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                WorkBuddyTerminator.terminateAll()
            }.value
            isKilling = false
            statusLine = appStatusLine()
            if report.remaining.isEmpty {
                alert = AppAlert(
                    title: "已关闭",
                    message: report.killedCount == 0
                        ? "没有检测到运行中的 WorkBuddy 进程"
                        : "已结束 \(report.killedCount) 个 WorkBuddy 进程，现在可以安全编辑会话了"
                )
            } else {
                alert = AppAlert(
                    title: "没能完全关闭",
                    message: "仍有 \(report.remaining.count) 个进程存活：\n"
                        + report.remaining.map { "· \(String($0.pid)) \(String($0.command.prefix(64)))" }
                            .joined(separator: "\n")
                )
            }
        }
    }

    // MARK: - 磁盘清理

    func scanDiskCleanup(retentionDays: Int) {
        diskCleanupResult = nil
        refreshDiskCleanup(retentionDays: retentionDays)
    }

    private func refreshDiskCleanup(retentionDays: Int) {
        diskCleanupTask?.cancel()
        diskCleanupCancellation?.cancel()
        let cancellation = DiskCleanupCancellation()
        diskCleanupCancellation = cancellation
        diskCleanupToken += 1
        let token = diskCleanupToken
        let selectedSource = source
        isCleaningDisk = false
        diskCleanupPreview = nil
        diskCleanupError = nil
        isScanningDisk = true
        diskCleanupTask = Task {
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try DiskCleanup.preview(
                        for: selectedSource,
                        retentionDays: retentionDays,
                        cancellation: cancellation
                    )
                }.value
                guard token == diskCleanupToken, selectedSource == source else { return }
                diskCleanupPreview = preview
                isScanningDisk = false
                isCleaningDisk = false
            } catch {
                guard token == diskCleanupToken, selectedSource == source else { return }
                diskCleanupError = error.localizedDescription
                isScanningDisk = false
            }
        }
    }

    func cleanDisk(categories: Set<DiskCleanupCategory>) {
        guard let preview = diskCleanupPreview, preview.source == source else { return }
        diskCleanupTask?.cancel()
        diskCleanupCancellation?.cancel()
        let cancellation = DiskCleanupCancellation()
        diskCleanupCancellation = cancellation
        diskCleanupToken += 1
        let token = diskCleanupToken
        let selectedSource = source
        isCleaningDisk = true
        diskCleanupError = nil
        diskCleanupResult = nil
        diskCleanupTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try DiskCleanup.clean(
                        preview: preview,
                        source: selectedSource,
                        categories: categories,
                        cancellation: cancellation
                    )
                }.value
                guard token == diskCleanupToken, selectedSource == source else { return }
                diskCleanupResult = result
                isCleaningDisk = false
                refreshDiskCleanup(retentionDays: preview.retentionDays)
            } catch {
                guard token == diskCleanupToken, selectedSource == source else { return }
                diskCleanupError = error.localizedDescription
                isCleaningDisk = false
            }
        }
    }

    func cancelDiskCleanup() {
        diskCleanupTask?.cancel()
        diskCleanupCancellation?.cancel()
        diskCleanupCancellation = nil
        diskCleanupToken += 1
        diskCleanupPreview = nil
        diskCleanupResult = nil
        diskCleanupError = nil
        isScanningDisk = false
        isCleaningDisk = false
    }

    // MARK: - 写操作

    func migrate(to target: Account) {
        guard let session = selectedSession else { return }
        guard !session.isCloudSynced else {
            alert = AppAlert(
                title: "云端会话",
                message: "「\(session.displayTitle)」是云端同步会话，改动归属可能被云端覆盖。请确认后重试。"
            )
            return
        }
        run {
            let changed = try self.db?.migrate(sessionID: session.id, to: target.uid) ?? false
            return changed ? "已迁移到 \(target.displayName)" : "已在 \(target.displayName) 下，无需变更"
        }
    }

    /// 永久删除是不可逆的，先把该删什么摆出来让用户过目。
    func requestPermanentDelete() {
        guard let session = selectedSession else { return }
        pendingDeletion = PendingDeletion(session: session, size: db?.transcriptSize(for: session) ?? 0)
    }

    func confirmPermanentDelete() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        run {
            let freed = try self.db?.hardDelete(sessionID: pending.session.id) ?? 0
            return freed > 0
                ? "已永久删除，释放 \(Self.formatBytes(freed))"
                : "已永久删除"
        }
    }

    func restore() {
        guard let session = selectedSession else { return }
        run {
            let changed = try self.db?.restoreFromTrash(sessionID: session.id) ?? false
            return changed ? "已还原" : "该会话不在回收站中"
        }
    }

    static func formatBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }

    private func run(_ body: @escaping () throws -> String?) {
        isBusy = true
        defer { isBusy = false }
        do {
            let message = try body()
            statusLine = message
            if let message { alert = AppAlert(title: "完成", message: message) }
            reload()
        } catch {
            alert = AppAlert(title: "操作失败", message: error.localizedDescription)
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 一次待确认的永久删除。
struct PendingDeletion: Identifiable {
    let id = UUID()
    let session: WorkSession
    /// 正文占用的字节数，用来告诉用户能省多少
    let size: Int
}
