import Foundation
import Darwin

/// WorkBuddy 的 GUI、sidecar 与后台网关进程。
///
/// GUI 退出后 sidecar 仍以 detached 方式存活——父进程被 init 收养，Command+Q 收不掉；
/// 网关进程同样自己脱离终端。
///
/// 识别只看可执行文件路径（argv[0]），不看整条命令行。后者会误伤：
/// 任何命令行里恰好写了「WorkBuddy AI.app」字样的进程——包括用户自己开的终端。
enum WorkBuddyProcess {
    struct Match {
        let pid: pid_t
        /// 可执行文件路径
        let executable: String
        /// 完整命令行
        let command: String

        /// sidecar 是 GUI 退出后残留的那个。
        var isSidecar: Bool { command.contains("sidecar-entry") }
    }

    /// 判断某个进程是否属于 WorkBuddy。
    ///
    /// - Parameters:
    ///   executable: 可执行文件路径，如 `/Applications/WorkBuddy AI.app/Contents/MacOS/Electron`
    ///   command: 完整命令行，仅用来区分网关与 node 运行时
    private static func isWorkBuddy(executable: String, command: String) -> Bool {
        let exe = executable.lowercased()
        let cmd = command.lowercased()

        // 两个发行版：可执行文件就躺在 app bundle 里。
        if exe.contains("workbuddy ai.app") || exe.contains("/workbuddy.app") { return true }

        // 网关与 WorkBuddy 自带的 node 运行时拉起的子进程（claude-code-router、fork-preload 等）。
        // 命令行里也查一遍——只看可执行文件会把拿这个 node 跑别的脚本的进程一起收掉。
        let binaryRoots = [".workbuddy-ai/binaries/", ".workbuddy/binaries/"]
        if binaryRoots.contains(where: exe.contains), cmd.contains("workbuddy") { return true }
        return false
    }

    /// 列出当前所有 WorkBuddy 相关进程，不含本进程。
    static func running() -> [Match] {
        (try? runningChecked()) ?? []
    }

    /// 进程扫描失败会抛错，供清理等必须确认 WorkBuddy 已退出的操作使用。
    static func runningChecked() throws -> [Match] {
        let commands = try psTable("command=")
        let executables = try psTable("comm=")
        let selfPID = getpid()
        return executables.compactMap { pid, executable in
            guard pid != selfPID else { return nil }
            let command = commands[pid] ?? executable
            guard isWorkBuddy(executable: executable, command: command) else { return nil }
            return Match(pid: pid, executable: executable, command: command)
        }
    }

    /// 取 ps 的一列，连同 pid 一起返回。列的内容可能自带空格，按首个分隔符切完余下全归它。
    private static func psTable(_ column: String) throws -> [pid_t: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,\(column)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "ps 退出码 \(process.terminationStatus)"])
        }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .reduce(into: [:]) { table, line in
                let trimmed = line.drop(while: { $0 == " " })
                guard let space = trimmed.firstIndex(of: " "),
                      let pid = pid_t(trimmed[trimmed.startIndex..<space]) else { return }
                let rest = trimmed[trimmed.index(after: space)...].drop(while: { $0 == " " })
                table[pid] = String(rest)
            }
    }
}

/// 结束 WorkBuddy 的全部进程。
///
/// GUI 退出时会顺手再拉一个 sidecar，所以先收 GUI，等它退干净，再收剩下的，
/// 最后对死不掉的补一刀。
enum WorkBuddyTerminator {
    struct Report {
        var terminated: [pid_t] = []
        var forced: [pid_t] = []
        var remaining: [WorkBuddyProcess.Match] = []

        var killedCount: Int { Set(terminated + forced).count }
    }

    static func terminateAll() -> Report {
        var report = Report()

        for match in WorkBuddyProcess.running() where !match.isSidecar {
            if kill(match.pid, SIGTERM) == 0 { report.terminated.append(match.pid) }
        }
        usleep(400_000)

        for match in WorkBuddyProcess.running() {
            if kill(match.pid, SIGTERM) == 0 { report.terminated.append(match.pid) }
        }
        usleep(400_000)

        for match in WorkBuddyProcess.running() {
            if kill(match.pid, SIGKILL) == 0 { report.forced.append(match.pid) }
        }
        usleep(300_000)

        report.remaining = WorkBuddyProcess.running()
        return report
    }
}
