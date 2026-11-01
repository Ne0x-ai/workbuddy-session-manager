import Foundation

/// 命令行自检入口。用 WBSM_DATA_DIR 指向沙箱数据目录即可在不动真实库的前提下
/// 验证读写全链路；`--selftest` 只跑读，`--selftest-write` 会实际写一次再复原。
enum Headless {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let mode = args.first(where: {
            $0 == "--selftest" || $0 == "--selftest-write" || $0 == "--selftest-disk-cleanup" || $0 == "--kill-workbuddy"
        }) else {
            return false
        }
        if mode == "--kill-workbuddy" { exit(killWorkBuddy()) }
        if mode == "--selftest-disk-cleanup" { exit(selfTestDiskCleanup()) }
        let dir = ProcessInfo.processInfo.environment["WBSM_DATA_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? Database.overseas
        exit(run(mode: mode, dataDir: dir))
    }

    private static func selfTestDiskCleanup() -> Int32 {
        do {
            print(try DiskCleanup.selfTest())
            return 0
        } catch {
            print("失败：\(error.localizedDescription)")
            return 1
        }
    }

    /// 命令行版的「关闭 WorkBuddy」，与 GUI 里那个按钮同一套逻辑。
    private static func killWorkBuddy() -> Int32 {
        let before = WorkBuddyProcess.running()
        print("检测到 \(before.count) 个 WorkBuddy 进程")
        for match in before {
            print("  \(match.pid)  \(match.command.prefix(90))")
        }
        let report = WorkBuddyTerminator.terminateAll()
        print("已结束 \(report.terminated.count) 个，强杀 \(report.forced.count) 个")
        guard report.remaining.isEmpty else {
            print("✗ 残留 \(report.remaining.count) 个：")
            for match in report.remaining { print("  \(match.pid)  \(match.command.prefix(90))") }
            return 1
        }
        print("✓ 已清空")
        return 0
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
            guard try db.migrate(sessionID: first.id, to: target.uid) else {
                print("迁移      无变化"); return 0
            }
            print("迁移后    归属 \(target.shortUID)")

            _ = try db.migrate(sessionID: first.id, to: accounts[0].uid)
            print("复原      归属 \(accounts[0].shortUID)  已还原")
            // 自检自己造的备份不留
            try? FileManager.default.removeItem(at: db.dataDir.appendingPathComponent("backups"))

            // 彻底删除不可逆，只在沙箱里试。真实库上删了用户就找不回来了。
            if ProcessInfo.processInfo.environment["WBSM_DATA_DIR"] != nil {
                let pool = try db.sessions(userID: accounts[0].uid, includeTrashed: false)
                // 优先挑真有正文文件的那个，否则测不到"文件也被删了"
                let victim = pool.first {
                    $0.id != first.id
                        && FileManager.default.fileExists(atPath: db.transcriptURL(for: $0).path)
                } ?? pool.first { $0.id != first.id }
                if let victim {
                    let file = db.transcriptURL(for: victim)
                    let hadFile = FileManager.default.fileExists(atPath: file.path)
                    let freed = try db.hardDelete(sessionID: victim.id)
                    let fileGone = !FileManager.default.fileExists(atPath: file.path)
                    let recordGone = try !db.sessions(userID: accounts[0].uid, includeTrashed: false)
                        .contains { $0.id == victim.id }
                    print("彻底删除  释放 \(freed) 字节  原有文件=\(hadFile) 现已删=\(fileGone) 记录已清=\(recordGone)")
                }
            } else {
                print("彻底删除  跳过（只在沙箱里测，真实库不碰）")
            }

            let (uid, nickname) = db.currentAccount() ?? ("-", nil)
            print("当前登录  \(nickname ?? "未知") \(String(uid.prefix(8)))")
            return 0
        } catch {
            print("失败：\(error.localizedDescription)")
            return 1
        }
    }
}
