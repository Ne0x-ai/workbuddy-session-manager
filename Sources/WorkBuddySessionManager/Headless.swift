import Foundation

/// 命令行自检入口。用 WBSM_DATA_DIR 指向沙箱数据目录即可在不动真实库的前提下
/// 验证读写全链路；`--selftest` 只跑读，`--selftest-write` 会实际写一次再复原。
enum Headless {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let mode = args.first(where: { $0 == "--selftest" || $0 == "--selftest-write" }) else {
            return false
        }
        let dir = ProcessInfo.processInfo.environment["WBSM_DATA_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? Database.overseas
        exit(run(mode: mode, dataDir: dir))
    }

    private static func run(mode: String, dataDir: URL) -> Int32 {
        do {
            let db = try Database(dataDir: dataDir)
            let accounts = try db.accounts()
            print("数据目录  \(dataDir.path)")
            print("账号      \(accounts.count) 个")
            for account in accounts {
                let tag = account.isCurrent ? " [当前]" : ""
                print("  \(account.displayName.padding(toLength: 26, withPad: " ", startingAt: 0))"
                    + "\(account.sessionCount) 会话 / 回收站 \(account.trashedCount)\(tag)")
            }

            guard let first = try db.sessions(userID: accounts[0].uid, includeTrashed: false).first else {
                print("没有会话可测"); return 0
            }
            let url = db.transcriptURL(for: first)
            let transcript = TranscriptRenderer.parse(at: url)
            print("正文      \(first.shortID) 缺失=\(transcript.isMissing) "
                + "对话=\(transcript.turns.count) 工具种类=\(transcript.toolCounts.count)")
            let leaked = transcript.turns.filter { $0.text.contains("<system-reminder>") || $0.text.contains("<user_query>") }.count
            print("注入泄漏  \(leaked)（应为 0）")

            // 导出是最容易整段丢失用户提问的一步，必须验落盘结果而不是只验内存里的解析。
            let md = TranscriptRenderer.markdown(session: first, transcript: transcript)
            let exportPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("wbsm-selftest-\(first.shortID).md")
            try md.write(to: exportPath, atomically: true, encoding: .utf8)
            let written = try String(contentsOf: exportPath, encoding: .utf8)
            let userTurns = written.components(separatedBy: "### 用户").count - 1
            let assistantTurns = written.components(separatedBy: "### 助手").count - 1
            let exportLeaked = ["<system-reminder>", "<user_query>", "<conversation_history_summary>"]
                .filter { written.contains($0) }.count
            print("导出      \(md.count) 字符 用户=\(userTurns) 助手=\(assistantTurns) 泄漏=\(exportLeaked)（应为 0）")
            try? FileManager.default.removeItem(at: exportPath)

            guard mode == "--selftest-write" else { return 0 }

            let other = accounts.first { $0.uid != accounts[0].uid }
            guard let target = other else { print("只有一个账号，跳过写测试"); return 0 }

            print("—— 写测试 ——")
            print("迁移前    \(String(first.id.prefix(8))) 归属 \(accounts[0].shortUID)")
            guard let backup = try db.migrate(sessionID: first.id, to: target.uid) else {
                print("迁移      无变化"); return 0
            }
            print("迁移后    归属 \(target.shortUID)  备份 \(backup.lastPathComponent)")
            print("回收站    \(try db.moveToTrash(sessionID: first.id) != nil ? "已移入" : "无变化")")
            print("还原      \(try db.restoreFromTrash(sessionID: first.id) != nil ? "已还原" : "无变化")")

            try? FileManager.default.removeItem(at: backup)
            _ = try db.migrate(sessionID: first.id, to: accounts[0].uid)
            print("复原      归属 \(accounts[0].shortUID)  已还原")

            let (uid, nickname) = db.currentAccount() ?? ("-", nil)
            print("当前登录  \(nickname ?? "未知") \(String(uid.prefix(8)))")
            return 0
        } catch {
            print("失败：\(error.localizedDescription)")
            return 1
        }
    }
}
