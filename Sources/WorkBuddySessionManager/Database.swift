import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum WBError: LocalizedError {
    case noDatabase(String)
    case schemaDrift([String])
    case appRunning([String])
    case queryFailed(String)
    case writeFailed(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .noDatabase(let p):
            "未找到 \(p)，请确认已安装 WorkBuddy 并至少启动过一次"
        case .schemaDrift(let cols):
            "数据库结构与预期不符，缺少字段：\(cols.joined(separator: ", "))。\n应用可能已升级，请勿写入。"
        case .appRunning(let pids):
            "WorkBuddy 仍在运行（\(pids.count) 个进程）。\n运行中写库会被应用内存状态覆盖，请先完全退出。"
        case .queryFailed(let m): "查询失败：\(m)"
        case .writeFailed(let m): "写入失败：\(m)"
        case .notFound(let m): m
        }
    }
}

/// 两个官方发行版各用独立的数据目录，账号、会话、库都不互通，
/// 所以界面上必须让用户明确当前在看哪一个。
enum DataSource: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overseas
    case domestic

    var id: String { rawValue }

    var appName: String {
        switch self {
        case .overseas: "WorkBuddy AI"
        case .domestic: "WorkBuddy"
        }
    }

    var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            self == .overseas ? ".workbuddy-ai" : ".workbuddy")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("workbuddy.db").path)
    }
}

/// WorkBuddy 的会话索引库。只读查询直接开只读连接，写操作走可写连接。
///
/// 账号隔离仅由 sessions.user_id 一列实现：正文存在按工作目录分组的 jsonl 中，
/// 不含账号信息。所以「迁移」就是改这一列，文件层无需变动。
final class Database {
    let dataDir: URL
    private var handle: OpaquePointer?

    static let requiredColumns = ["id", "user_id", "cwd", "title", "transport", "deleted_at"]

    static let overseas = DataSource.overseas.directory
    static let domestic = DataSource.domestic.directory

    var dbURL: URL { dataDir.appendingPathComponent("workbuddy.db") }

    init(dataDir: URL) throws {
        self.dataDir = dataDir
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw WBError.noDatabase(dbURL.path)
        }
        try open()
        try validateSchema()
    }

    deinit { if let handle { sqlite3_close(handle) } }

    private func open() throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw WBError.queryFailed(msg)
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    // MARK: - 查询

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw WBError.queryFailed(lastError)
        }
        return stmt
    }

    private var lastError: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
    }

    private func errorText(_ db: OpaquePointer?) -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
    }

    private func validateSchema() throws {
        let stmt = try prepare("PRAGMA table_info(sessions)")
        defer { sqlite3_finalize(stmt) }
        var found = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { found.insert(String(cString: c)) }
        }
        let missing = Self.requiredColumns.filter { !found.contains($0) }
        if !missing.isEmpty { throw WBError.schemaDrift(missing) }
    }

    /// 当前登录账号的昵称只在 snapshot 里，仅覆盖正在使用的那一个。
    func currentAccount() -> (uid: String, nickname: String?)? {
        let path = dataDir.appendingPathComponent("storage/skeleton/account-snapshot.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let primary = root["primary"] as? [String: Any],
              let uid = primary["uid"] as? String
        else { return nil }
        return (uid, primary["nickname"] as? String)
    }

    func accounts() throws -> [Account] {
        let sql = """
            SELECT user_id,
                   COUNT(*) AS total,
                   SUM(CASE WHEN deleted_at IS NULL THEN 1 ELSE 0 END) AS alive,
                   SUM(CASE WHEN deleted_at IS NOT NULL THEN 1 ELSE 0 END) AS trashed,
                   SUM(CASE WHEN deleted_at IS NULL AND transport='cloud' THEN 1 ELSE 0 END) AS cloud,
                   MAX(updated_at) AS last
            FROM sessions GROUP BY user_id ORDER BY total DESC
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        let current = currentAccount()
        var result: [Account] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uid = String(cString: sqlite3_column_text(stmt, 0))
            result.append(Account(
                uid: uid,
                nickname: uid == current?.uid ? current?.nickname : nil,
                sessionCount: Int(sqlite3_column_int(stmt, 1)),
                trashedCount: Int(sqlite3_column_int(stmt, 3)),
                cloudCount: Int(sqlite3_column_int(stmt, 4)),
                lastActivity: Self.dateFromMillis(sqlite3_column_int64(stmt, 5)),
                isCurrent: uid == current?.uid
            ))
        }
        return result
    }

    func sessions(userID: String, includeTrashed: Bool) throws -> [WorkSession] {
        // deleted_at 有三态：NULL 未删、正数 已删、-1 云端会话的哨兵值。
        // 回收站只认正数，-1 既不是已删也不是未删，两边都不归它。
        let sql = """
            SELECT id, user_id, COALESCE(title,''), cwd, transport,
                   created_at, updated_at, deleted_at
            FROM sessions
            WHERE user_id = ?1 AND \(includeTrashed ? "deleted_at > 0" : "deleted_at IS NULL")
            ORDER BY updated_at DESC
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, userID, -1, SQLITE_TRANSIENT)
        var result: [WorkSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(WorkSession(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                userID: String(cString: sqlite3_column_text(stmt, 1)),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                cwd: String(cString: sqlite3_column_text(stmt, 3)),
                transport: String(cString: sqlite3_column_text(stmt, 4)),
                createdAt: Self.dateFromMillis(sqlite3_column_int64(stmt, 5)) ?? .distantPast,
                updatedAt: Self.dateFromMillis(sqlite3_column_int64(stmt, 6)) ?? .distantPast,
                deletedAt: Self.dateFromMillis(sqlite3_column_int64(stmt, 7))
            ))
        }
        return result
    }

    func allSessions(includeTrashed: Bool) throws -> [WorkSession] {
        let sql = """
            SELECT id, user_id, COALESCE(title,''), cwd, transport,
                   created_at, updated_at, deleted_at
            FROM sessions
            \(includeTrashed ? "" : "WHERE deleted_at IS NULL")
            ORDER BY updated_at DESC
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var result: [WorkSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(WorkSession(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                userID: String(cString: sqlite3_column_text(stmt, 1)),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                cwd: String(cString: sqlite3_column_text(stmt, 3)),
                transport: String(cString: sqlite3_column_text(stmt, 4)),
                createdAt: Self.dateFromMillis(sqlite3_column_int64(stmt, 5)) ?? .distantPast,
                updatedAt: Self.dateFromMillis(sqlite3_column_int64(stmt, 6)) ?? .distantPast,
                deletedAt: Self.dateFromMillis(sqlite3_column_int64(stmt, 7))
            ))
        }
        return result
    }

    // MARK: - 正文路径

    /// projects/ 下的目录名是工作目录去掉前导斜杠后把 / 换成 -。
    func transcriptURL(for session: WorkSession) -> URL {
        Self.transcriptURL(at: dataDir, for: session)
    }

    // MARK: - 写操作

    /// 返回运行中的 WorkBuddy 进程 pid；空数组表示已退出。
    /// sidecar 与网关也算——它们同样持有数据目录里的文件。
    static func runningProcessIDs() -> [String] {
        WorkBuddyProcess.running().map { String($0.pid) }.sorted()
    }

    /// 用 SQLite backup API 生成一致性副本，避免裸拷贝遇到半截 WAL。
    @discardableResult
    func makeBackup() throws -> URL {
        let dest = try Self.backupURL(in: dataDir)
        var destDB: OpaquePointer?
        guard sqlite3_open_v2(dest.path, &destDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let destDB else {
            throw WBError.writeFailed("无法创建备份文件")
        }
        guard let backup = sqlite3_backup_init(destDB, "main", handle, "main") else {
            sqlite3_close(destDB)
            throw WBError.writeFailed("备份初始化失败")
        }
        let status = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        // 备份 API 逐页复制，源库的 WAL 标记也被写进了目标库文件头。干净关闭的 WAL 库
        // 不带 -shm，而只读连接打不开这种库（error 14），所以先落回回滚日志模式，
        // 让备份成为可独立打开校验、也能直接拷回去的单文件。
        var reset: OpaquePointer?
        if sqlite3_prepare_v2(destDB, "PRAGMA journal_mode=DELETE", -1, &reset, nil) == SQLITE_OK {
            sqlite3_step(reset)
            sqlite3_finalize(reset)
        }
        // 必须先关闭目标库，否则另开连接读到的可能是不完整的 WAL 视图。
        sqlite3_close(destDB)
        // 模式已回退，主文件自包含，此时残留的 -wal/-shm 必然是废弃的。
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dest.path + suffix)
        }
        guard status == SQLITE_DONE else {
            try? FileManager.default.removeItem(at: dest)
            throw WBError.writeFailed("备份写入未完成")
        }
        var checkDB: OpaquePointer?
        guard sqlite3_open_v2(dest.path, &checkDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let checkDB else {
            throw WBError.writeFailed("无法打开备份校验：\(errorText(checkDB))")
        }
        defer { sqlite3_close(checkDB) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(checkDB, "PRAGMA integrity_check", -1, &stmt, nil) == SQLITE_OK else {
            throw WBError.writeFailed("无法校验备份：\(errorText(checkDB))")
        }
        defer { sqlite3_finalize(stmt) }
        var verdict = "unknown"
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            verdict = String(cString: c)
        }
        guard verdict == "ok" else {
            try? FileManager.default.removeItem(at: dest)
            throw WBError.writeFailed("备份完整性校验未通过（\(verdict)）")
        }
        Self.pruneBackups(in: dataDir)
        return dest
    }

    /// 改归属。这是唯一不可逆的写操作——原归属写成功后就没处查了，所以留一份备份。
    /// - Returns: 是否真的发生了迁移
    @discardableResult
    func migrate(sessionID: String, to targetUID: String) throws -> Bool {
        try assertWritable()
        guard let current = try accountOf(sessionID) else { throw WBError.notFound("未找到会话 \(sessionID)") }
        if current.userID == targetUID { return false }

        let backup = try makeBackup()
        try execute("UPDATE sessions SET user_id = ?1 WHERE id = ?2", [targetUID, sessionID])
        guard let after = try accountOf(sessionID), after.userID == targetUID else {
            try? FileManager.default.removeItem(at: backup)
            try execute("UPDATE sessions SET user_id = ?1 WHERE id = ?2", [current.userID, sessionID])
            throw WBError.writeFailed("写入后校验失败，已自动回滚")
        }
        return true
    }

    /// 彻底删除：正文文件和索引记录一起清掉，磁盘空间立刻回来。
    ///
    /// 不做软删除——标个 deleted_at 的话正文还占着磁盘，这个工具就白做了。
    /// 不可恢复，所以调用方必须先跟用户确认。
    /// - Returns: 释放的字节数
    @discardableResult
    func hardDelete(sessionID: String) throws -> Int {
        try assertWritable()
        guard let current = try accountOf(sessionID) else { throw WBError.notFound("未找到会话 \(sessionID)") }
        let fm = FileManager.default
        let file = transcriptURL(for: current)

        let attrs: [FileAttributeKey: Any]?
        do {
            attrs = try fm.attributesOfItem(atPath: file.path)
        } catch {
            let nsError = error as NSError
            guard nsError.domain == NSCocoaErrorDomain,
                  nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue else {
                throw error
            }
            attrs = nil
        }
        let freed = (attrs?[.size] as? Int) ?? 0

        try execute("BEGIN IMMEDIATE", [])
        do {
            try execute("DELETE FROM session_usage WHERE session_id = ?1", [sessionID])
            try execute("DELETE FROM sessions WHERE id = ?1", [sessionID])
            if attrs != nil { try fm.removeItem(at: file) }
            try execute("COMMIT", [])
        } catch {
            try? execute("ROLLBACK", [])
            throw error
        }

        let folder = file.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fm.removeItem(at: folder)
        }
        return freed
    }

    /// 正文占多大。删之前先告诉用户能省多少。
    func transcriptSize(for session: WorkSession) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptURL(for: session).path)
        return (attrs?[.size] as? Int) ?? 0
    }

    /// 从回收站还原：只把 deleted_at 抹掉，正文本来就没动过。
    @discardableResult
    func restoreFromTrash(sessionID: String) throws -> Bool {
        try assertWritable()
        guard let current = try accountOf(sessionID) else { throw WBError.notFound("未找到会话 \(sessionID)") }
        // deleted_at = -1 是云端会话的哨兵值，会被解成 1969 年，不是「删过」的语义
        guard let deletedAt = current.deletedAt, deletedAt.timeIntervalSince1970 > 1_600_000_000 else {
            return false
        }

        try execute("UPDATE sessions SET deleted_at = NULL WHERE id = ?1", [sessionID])
        return true
    }

    /// 守卫只保护正在被应用使用的真实数据目录。经 WBSM_DATA_DIR 指向的副本
    /// 没有活状态要保护，拦下来只会让自检无法进行。
    private var isLiveDataDir: Bool {
        let mine = dataDir.standardizedFileURL
        return DataSource.allCases.contains { $0.directory.standardizedFileURL == mine }
    }

    private func assertWritable() throws {
        guard isLiveDataDir else { return }
        let pids = Self.runningProcessIDs()
        if !pids.isEmpty { throw WBError.appRunning(pids) }
    }

    private func accountOf(_ sessionID: String) throws -> WorkSession? {
        let stmt = try prepare("SELECT id, user_id, COALESCE(title,''), cwd, transport, created_at, updated_at, deleted_at FROM sessions WHERE id = ?1")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return WorkSession(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            userID: String(cString: sqlite3_column_text(stmt, 1)),
            title: String(cString: sqlite3_column_text(stmt, 2)),
            cwd: String(cString: sqlite3_column_text(stmt, 3)),
            transport: String(cString: sqlite3_column_text(stmt, 4)),
            createdAt: Self.dateFromMillis(sqlite3_column_int64(stmt, 5)) ?? .distantPast,
            updatedAt: Self.dateFromMillis(sqlite3_column_int64(stmt, 6)) ?? .distantPast,
            deletedAt: Self.dateFromMillis(sqlite3_column_int64(stmt, 7))
        )
    }

    private func execute(_ sql: String, _ bindings: [String]) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw WBError.writeFailed(lastError) }
    }

    // MARK: - 时间

    private static var millisFromNow: String {
        String(Int64(Date().timeIntervalSince1970 * 1000))
    }

    static func dateFromMillis(_ value: Int64) -> Date? {
        value == 0 ? nil : Date(timeIntervalSince1970: Double(value) / 1000)
    }

    private static func filenameTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// 连续几次写操作可能落在同一秒内，靠秒级时间戳会互相覆盖备份。
    /// 备份统一放数据目录下的 backups/，不再往家目录里撒文件。
    private static func backupURL(in dataDir: URL) throws -> URL {
        let dir = dataDir.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = filenameTimestamp()
        var candidate = dir.appendingPathComponent("workbuddy.db.bak-\(stamp)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("workbuddy.db.bak-\(stamp)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// 只留最近几份。备份是用来兜底的，不是用来攒的。
    private static func pruneBackups(in dataDir: URL, keeping limit: Int = 5) {
        let fm = FileManager.default
        let dir = dataDir.appendingPathComponent("backups")
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        // 文件名里的时间戳定长，字典序即时间序
        let backups = items
            .filter { $0.lastPathComponent.hasPrefix("workbuddy.db.bak-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for stale in backups.dropLast(limit) {
            try? fm.removeItem(at: stale)
        }
    }
}

// MARK: - 后台读取

/// Database 持有 sqlite 连接，不能跨并发边界传递，所以后台任务各自开一次短连接，
/// 只把值类型的结果带回来。写操作仍然走 AppState 持有的那个长连接。
extension Database {
    static func accounts(at dataDir: URL) throws -> [Account] {
        try Database(dataDir: dataDir).accounts()
    }

    static func sessions(at dataDir: URL, userID: String, includeTrashed: Bool) throws -> [WorkSession] {
        try Database(dataDir: dataDir).sessions(userID: userID, includeTrashed: includeTrashed)
    }

    static func transcript(at dataDir: URL, session: WorkSession) -> Transcript {
        TranscriptRenderer.parse(at: transcriptURL(at: dataDir, for: session))
    }

    static func transcriptURL(at dataDir: URL, for session: WorkSession) -> URL {
        let folder = session.cwd
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "-")
        return dataDir
            .appendingPathComponent("projects")
            .appendingPathComponent(folder)
            .appendingPathComponent("\(session.id).jsonl")
    }
}
