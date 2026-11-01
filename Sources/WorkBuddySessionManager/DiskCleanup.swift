import Foundation
import Darwin

struct DiskCleanupFile: Sendable {
    let category: DiskCleanupCategory
    let relativePath: String
    let size: Int
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let device: UInt64
    let inode: UInt64
}

enum DiskCleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case logs
    case sandboxLogs
    case traces
    case cache

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logs: "日志"
        case .sandboxLogs: "Sandbox 日志"
        case .traces: "运行追踪"
        case .cache: "缓存"
        }
    }

    var systemImage: String {
        switch self {
        case .logs, .sandboxLogs: "doc.text"
        case .traces: "point.3.connected.trianglepath.dotted"
        case .cache: "shippingbox"
        }
    }

    var relativeRoot: String {
        switch self {
        case .logs: "logs"
        case .sandboxLogs: "logs/sandbox"
        case .traces: "traces"
        case .cache: "cache"
        }
    }
}

struct DiskCleanupSummary: Identifiable, Sendable {
    let category: DiskCleanupCategory
    let fileCount: Int
    let bytes: Int

    var id: String { category.id }
}

struct DiskCleanupPreview: Sendable {
    let source: DataSource
    let dataDirectory: URL
    let retentionDays: Int
    let createdAt: Date
    let files: [DiskCleanupFile]
    let summaries: [DiskCleanupSummary]

    var totalFiles: Int { files.count }
    var totalBytes: Int { files.reduce(0) { $0 + $1.size } }
}

struct DiskCleanupResult: Sendable {
    let deletedFiles: Int
    let freedBytes: Int
    let skippedChangedFiles: Int
    let failures: [String]
    let stopReason: String?
}

final class DiskCleanupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled { throw CancellationError() }
    }
}

enum DiskCleanupError: LocalizedError {
    case sourceNotInstalled(String)
    case unsafeRoot(String)
    case workBuddyRunning([String])
    case cannotCheckProcesses(String)
    case invalidPreview
    case scanFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotInstalled(let name): "未检测到 \(name)，无法清理。"
        case .unsafeRoot(let path): "清理目录不安全，已拒绝操作：\(path)"
        case .workBuddyRunning(let pids):
            "WorkBuddy 仍在运行（\(pids.joined(separator: "、"))）。请先完全退出，再重试。"
        case .cannotCheckProcesses(let message): "无法确认 WorkBuddy 是否已退出，已停止清理：\(message)"
        case .invalidPreview: "清理预览已失效，请重新扫描。"
        case .scanFailed(let message): "扫描失败：\(message)"
        }
    }
}

enum DiskCleanup {
    static let retentionOptions = [7, 30, 90]

    static func preview(
        for source: DataSource,
        retentionDays: Int,
        cancellation: DiskCleanupCancellation
    ) throws -> DiskCleanupPreview {
        guard source.isInstalled else { throw DiskCleanupError.sourceNotInstalled(source.appName) }
        try requireWorkBuddyClosed()
        return try scan(
            dataDirectory: source.directory,
            source: source,
            retentionDays: retentionDays,
            now: Date(),
            cancellation: cancellation
        )
    }

    static func clean(
        preview: DiskCleanupPreview,
        source: DataSource,
        categories: Set<DiskCleanupCategory>,
        cancellation: DiskCleanupCancellation
    ) throws -> DiskCleanupResult {
        guard preview.source == source,
              preview.dataDirectory.standardizedFileURL == source.directory.standardizedFileURL,
              source.isInstalled else {
            throw DiskCleanupError.invalidPreview
        }
        try requireWorkBuddyClosed()
        return clean(preview: preview, categories: categories, checkProcesses: true, cancellation: cancellation)
    }

    static func selfTest() throws -> String {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .appendingPathComponent("wbsm-disk-cleanup-\(UUID().uuidString)", isDirectory: true)
        let root = sandbox.appendingPathComponent("data", isDirectory: true)
        let external = sandbox.appendingPathComponent("outside.log")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let old = Date().addingTimeInterval(-20 * 24 * 60 * 60)
        let fresh = Date()
        let files: [(String, String, Date)] = [
            ("logs/old.log", "old log", old),
            ("logs/new.log", "new log", fresh),
            ("logs/sandbox/old.log", "sandbox log", old),
            ("traces/old.jsonl", "trace", old),
            ("cache/old.json", "cache", old),
            ("workspace/protected.log", "protected", old),
        ]
        for (path, contents, date) in files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try Data("external".utf8).write(to: external)
        try fm.createSymbolicLink(at: root.appendingPathComponent("logs/outside.log"), withDestinationURL: external)
        let database = root.appendingPathComponent("workbuddy.db")
        try Data("untouched".utf8).write(to: database)

        var preview = try scan(
            dataDirectory: root,
            source: .overseas,
            retentionDays: 7,
            now: fresh,
            checkProcesses: false,
            cancellation: DiskCleanupCancellation()
        )
        guard preview.summaries.first(where: { $0.category == .logs })?.fileCount == 1,
              preview.summaries.first(where: { $0.category == .sandboxLogs })?.fileCount == 1,
              preview.totalFiles == 4 else {
            throw DiskCleanupError.scanFailed("沙箱文件分类或超期筛选错误")
        }

        let changedTrace = root.appendingPathComponent("traces/old.jsonl")
        try fm.setAttributes([.modificationDate: fresh], ofItemAtPath: changedTrace.path)
        let addedAfterPreview = root.appendingPathComponent("logs/added-after-preview.log")
        try Data("not in preview".utf8).write(to: addedAfterPreview)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: addedAfterPreview.path)

        let result = clean(
            preview: preview,
            categories: Set(DiskCleanupCategory.allCases),
            checkProcesses: false,
            cancellation: DiskCleanupCancellation()
        )
        guard result.deletedFiles == 3,
              result.skippedChangedFiles == 1,
              result.failures.isEmpty,
              result.freedBytes == Data("old log".utf8).count
                + Data("sandbox log".utf8).count
                + Data("cache".utf8).count,
              fm.fileExists(atPath: root.appendingPathComponent("logs/new.log").path),
              fm.fileExists(atPath: addedAfterPreview.path),
              fm.fileExists(atPath: changedTrace.path),
              fm.fileExists(atPath: root.appendingPathComponent("workspace/protected.log").path),
              fm.fileExists(atPath: root.appendingPathComponent("logs/outside.log").path),
              String(data: try Data(contentsOf: external), encoding: .utf8) == "external",
              String(data: try Data(contentsOf: database), encoding: .utf8) == "untouched" else {
            throw DiskCleanupError.scanFailed("删除范围或快照复核错误")
        }

        let blocked = root.appendingPathComponent("logs/blocked")
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        let blockedFile = blocked.appendingPathComponent("old.log")
        try Data("blocked".utf8).write(to: blockedFile)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: blockedFile.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }
        preview = try scan(
            dataDirectory: root,
            source: .overseas,
            retentionDays: 7,
            now: fresh,
            checkProcesses: false,
            cancellation: DiskCleanupCancellation()
        )
        let failed = clean(
            preview: preview,
            categories: [.logs],
            checkProcesses: false,
            cancellation: DiskCleanupCancellation()
        )
        guard failed.failures.count == 1, fm.fileExists(atPath: blockedFile.path) else {
            throw DiskCleanupError.scanFailed("删除失败未正确保留文件")
        }
        return "磁盘清理自检通过：超期清理、快照保护、符号链接隔离、数据库与工作区保护、失败保留。"
    }

    private static func scan(
        dataDirectory: URL,
        source: DataSource,
        retentionDays: Int,
        now: Date,
        checkProcesses: Bool = true,
        cancellation: DiskCleanupCancellation
    ) throws -> DiskCleanupPreview {
        guard retentionOptions.contains(retentionDays) else { throw DiskCleanupError.invalidPreview }
        let root = dataDirectory.standardizedFileURL
        let rootInfo = try fileInfo(root)
        guard rootInfo.isDirectory, !rootInfo.isSymbolicLink else {
            throw DiskCleanupError.unsafeRoot(root.path)
        }
        if checkProcesses { try requireWorkBuddyClosed() }

        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        var selected: [DiskCleanupFile] = []
        for category in DiskCleanupCategory.allCases {
            let categoryRoot = root.appendingPathComponent(category.relativeRoot, isDirectory: true)
            guard let categoryInfo = try fileInfoIfPresent(categoryRoot) else { continue }
            guard categoryInfo.isDirectory, !categoryInfo.isSymbolicLink else {
                throw DiskCleanupError.unsafeRoot(categoryRoot.path)
            }
            for url in try regularFiles(
                under: categoryRoot,
                excludingSandboxLogs: category == .logs,
                dataDirectory: root,
                cancellation: cancellation
            ) {
                try cancellation.check()
                let info = try fileInfo(url)
                guard info.modifiedDate < cutoff,
                      let relativePath = relativePath(of: url, under: categoryRoot) else { continue }
                selected.append(DiskCleanupFile(
                    category: category,
                    relativePath: relativePath,
                    size: info.size,
                    modifiedSeconds: info.modifiedSeconds,
                    modifiedNanoseconds: info.modifiedNanoseconds,
                    device: info.device,
                    inode: info.inode
                ))
            }
        }

        let summaries = DiskCleanupCategory.allCases.map { category in
            let files = selected.filter { $0.category == category }
            return DiskCleanupSummary(category: category, fileCount: files.count, bytes: files.reduce(0) { $0 + $1.size })
        }
        return DiskCleanupPreview(
            source: source,
            dataDirectory: root,
            retentionDays: retentionDays,
            createdAt: now,
            files: selected,
            summaries: summaries
        )
    }

    private static func clean(
        preview: DiskCleanupPreview,
        categories: Set<DiskCleanupCategory>,
        checkProcesses: Bool,
        cancellation: DiskCleanupCancellation
    ) -> DiskCleanupResult {
        let fm = FileManager.default
        let cutoff = preview.createdAt.addingTimeInterval(-Double(preview.retentionDays) * 24 * 60 * 60)
        let files = preview.files.filter { categories.contains($0.category) }
        var deleted = 0
        var freed = 0
        var skipped = 0
        var failures: [String] = []
        var stopReason: String?
        var changedDirectories: [DiskCleanupCategory: Set<URL>] = [:]

        var lastProcessCheck = 0.0
        for (index, file) in files.enumerated() {
            if checkProcesses && (index == 0 || ProcessInfo.processInfo.systemUptime - lastProcessCheck >= 0.5) {
                do {
                    try requireWorkBuddyClosed()
                    lastProcessCheck = ProcessInfo.processInfo.systemUptime
                } catch {
                    stopReason = error.localizedDescription
                    break
                }
            }
            do {
                try cancellation.check()
                let url = try validatedURL(for: file, root: preview.dataDirectory)
                let current = try fileInfo(url)
                guard current.isRegularFile,
                      !current.isSymbolicLink,
                      current.size == file.size,
                      current.modifiedSeconds == file.modifiedSeconds,
                      current.modifiedNanoseconds == file.modifiedNanoseconds,
                      current.device == file.device,
                      current.inode == file.inode,
                      current.modifiedDate < cutoff else {
                    skipped += 1
                    continue
                }
                try fm.removeItem(at: url)
                deleted += 1
                freed += file.size
                let categoryRoot = preview.dataDirectory.appendingPathComponent(file.category.relativeRoot, isDirectory: true)
                var parent = url.deletingLastPathComponent()
                while parent.path != categoryRoot.path && parent.path.hasPrefix(categoryRoot.path + "/") {
                    changedDirectories[file.category, default: []].insert(parent)
                    parent.deleteLastPathComponent()
                }
            } catch is CancellationError {
                stopReason = "清理已取消"
                break
            } catch {
                if failures.count < 20 {
                    failures.append("\(file.relativePath)：\(error.localizedDescription)")
                }
            }
        }

        for category in DiskCleanupCategory.allCases {
            let categoryRoot = preview.dataDirectory.appendingPathComponent(category.relativeRoot, isDirectory: true)
            let directories = (changedDirectories[category] ?? []).sorted { $0.path.count > $1.path.count }
            for directory in directories where directory.path != categoryRoot.path {
                guard let info = try? fileInfo(directory), info.isDirectory, !info.isSymbolicLink,
                      let contents = try? fm.contentsOfDirectory(atPath: directory.path), contents.isEmpty else { continue }
                try? fm.removeItem(at: directory)
            }
        }
        return DiskCleanupResult(
            deletedFiles: deleted,
            freedBytes: freed,
            skippedChangedFiles: skipped,
            failures: failures,
            stopReason: stopReason
        )
    }

    private struct FileInfo {
        let isDirectory: Bool
        let isRegularFile: Bool
        let isSymbolicLink: Bool
        let size: Int
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let device: UInt64
        let inode: UInt64

        var modifiedDate: Date {
            Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
        }
    }

    private static func fileInfoIfPresent(_ url: URL) throws -> FileInfo? {
        do {
            return try fileInfo(url)
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
    }

    private static func fileInfo(_ url: URL) throws -> FileInfo {
        var value = stat()
        let result = url.path.withCString { lstat($0, &value) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let kind = value.st_mode & mode_t(S_IFMT)
        return FileInfo(
            isDirectory: kind == mode_t(S_IFDIR),
            isRegularFile: kind == mode_t(S_IFREG),
            isSymbolicLink: kind == mode_t(S_IFLNK),
            size: Int(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino)
        )
    }

    private static func validatedURL(for file: DiskCleanupFile, root: URL) throws -> URL {
        let components = file.relativePath.split(separator: "/")
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }),
              !file.relativePath.hasPrefix("/") else {
            throw DiskCleanupError.unsafeRoot(file.relativePath)
        }
        let dataRootInfo = try fileInfo(root)
        guard dataRootInfo.isDirectory, !dataRootInfo.isSymbolicLink else { throw DiskCleanupError.unsafeRoot(root.path) }
        let categoryRoot = root.appendingPathComponent(file.category.relativeRoot, isDirectory: true).standardizedFileURL
        var current = categoryRoot
        let rootInfo = try fileInfo(current)
        guard rootInfo.isDirectory, !rootInfo.isSymbolicLink else { throw DiskCleanupError.unsafeRoot(current.path) }
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            let info = try fileInfo(current)
            guard !info.isSymbolicLink else { throw DiskCleanupError.unsafeRoot(current.path) }
            if index < components.count - 1, !info.isDirectory {
                throw DiskCleanupError.unsafeRoot(current.path)
            }
        }
        guard current.path.hasPrefix(categoryRoot.path + "/") else { throw DiskCleanupError.unsafeRoot(current.path) }
        if file.category == .logs,
           current.path == root.appendingPathComponent("logs/sandbox").path
            || current.path.hasPrefix(root.appendingPathComponent("logs/sandbox").path + "/") {
            throw DiskCleanupError.unsafeRoot(current.path)
        }
        return current
    }

    private static func regularFiles(
        under root: URL,
        excludingSandboxLogs: Bool,
        dataDirectory: URL,
        cancellation: DiskCleanupCancellation
    ) throws -> [URL] {
        let fm = FileManager.default
        var pending = [root]
        var files: [URL] = []
        while let directory = pending.popLast() {
            try cancellation.check()
            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
            } catch {
                throw DiskCleanupError.scanFailed("无法读取目录 \(directory.lastPathComponent)：\(error.localizedDescription)")
            }
            for entry in entries {
                let info = try fileInfo(entry)
                if info.isSymbolicLink { continue }
                if info.isDirectory {
                    if excludingSandboxLogs,
                       entry.standardizedFileURL == dataDirectory.appendingPathComponent("logs/sandbox", isDirectory: true).standardizedFileURL {
                        continue
                    }
                    pending.append(entry)
                } else if info.isRegularFile {
                    files.append(entry)
                }
            }
        }
        return files
    }

    private static func relativePath(of url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func requireWorkBuddyClosed() throws {
        let matches: [WorkBuddyProcess.Match]
        do {
            matches = try WorkBuddyProcess.runningChecked()
        } catch {
            throw DiskCleanupError.cannotCheckProcesses(error.localizedDescription)
        }
        guard matches.isEmpty else {
            throw DiskCleanupError.workBuddyRunning(matches.map { String($0.pid) })
        }
    }
}

