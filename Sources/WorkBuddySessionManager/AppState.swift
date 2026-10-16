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
    @Published var isLoadingSessions = false
    @Published var isLoadingTranscript = false

    /// 两个发行版各用一套库，切换就是换整个数据目录。
    @Published var source: DataSource = .overseas {
        didSet { if source != oldValue { bootstrap() } }
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
            let backup = try self.db?.migrate(sessionID: session.id, to: target.uid)
            return backup.map { "已迁移到 \(target.displayName)，备份：\($0.lastPathComponent)" }
                ?? "已在 \(target.displayName) 下，无需变更"
        }
    }

    func moveToTrash() {
        guard let session = selectedSession else { return }
        run {
            let backup = try self.db?.moveToTrash(sessionID: session.id)
            return backup.map { "已移入回收站，备份：\($0.lastPathComponent)" } ?? "该会话已在回收站中"
        }
    }

    func restore() {
        guard let session = selectedSession else { return }
        run {
            let backup = try self.db?.restoreFromTrash(sessionID: session.id)
            return backup.map { "已还原，备份：\($0.lastPathComponent)" } ?? "该会话不在回收站中"
        }
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
