import Foundation

/// 本地已知的一个 WorkBuddy 账号。昵称只有当前登录的那个能从 snapshot 读到，
/// 其余账号仅能标识 uid——磁盘上没有留存其它账号的身份信息。
struct Account: Identifiable, Hashable, Sendable {
    let uid: String
    var nickname: String?
    var sessionCount: Int
    var trashedCount: Int
    var cloudCount: Int
    var lastActivity: Date?
    var isCurrent: Bool

    var id: String { uid }

    var displayName: String {
        if let nickname { return nickname }
        return String(uid.prefix(8))
    }

    var shortUID: String { String(uid.prefix(8)) }
}

/// 一条会话在索引库中的记录。正文另存于 projects/<工作目录>/<id>.jsonl。
struct WorkSession: Identifiable, Hashable, Sendable {
    let id: String
    var userID: String
    var title: String
    var cwd: String
    var transport: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    var shortID: String { String(id.prefix(8)) }
    var displayTitle: String { title.isEmpty ? "未命名会话" : title }
    var isCloudSynced: Bool { transport == "cloud" }
    var isTrashed: Bool { deletedAt != nil }
}

/// 正文里的一条对话。toolCall 只用于计数展示，正文不展开。
struct Turn: Identifiable, Hashable, Sendable {
    enum Speaker: String { case user, assistant }
    let id = UUID()
    let speaker: Speaker
    let text: String
}
