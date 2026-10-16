import Foundation

struct Transcript: Sendable {
    var turns: [Turn] = []
    var toolCounts: [String: Int] = [:]
    var isMissing: Bool = false

    var toolSummary: String {
        toolCounts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: "、")
    }
}

/// 解析会话正文 jsonl。
///
/// WorkBuddy 把真实提问包在 <user_query> 里，同时往同一条消息注入若干上下文块
/// （<system-reminder>、<memory_and_skills_reminder> 等）。直接取整个 content 会让
/// 提问被系统提示淹没，所以先抽出 user_query，再把注入块整段剥掉。
enum TranscriptRenderer {
    private static let injectedTags = [
        "system-reminder", "memory_and_skills_reminder", "conversation_history_summary",
        "current_time", "craft_mode", "user_info", "user_references", "project_layout",
        "summary", "status",
    ]

    private static let userQueryPattern = try! NSRegularExpression(
        pattern: "<user_query>(.*?)</user_query>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static let injectedPattern = try! NSRegularExpression(
        pattern: "<(\(injectedTags.joined(separator: "|")))\\b[^>]*>.*?</\\1>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static let toolNoisePrefixes = ["Called the ", "Result of calling "]

    static func parse(at url: URL) -> Transcript {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return Transcript(isMissing: true)
        }
        return parse(jsonl: text)
    }

    static func parse(jsonl: String) -> Transcript {
        var transcript = Transcript()
        let decoder = JSONDecoder()

        for line in textLines(of: jsonl) {
            guard let data = line.data(using: .utf8),
                  let object = try? decoder.decode(TranscriptEntry.self, from: data)
            else { continue }

            switch object.type {
            case "message":
                let raw = object.content?.map(\.text).joined(separator: "\n") ?? ""
                guard !raw.isEmpty else { continue }
                let cleaned = object.role == "user" ? userPrompt(from: raw) : assistantText(from: raw)
                guard !cleaned.isEmpty else { continue }
                transcript.turns.append(Turn(
                    speaker: object.role == "user" ? .user : .assistant,
                    text: cleaned
                ))
            case "function_call":
                if let name = object.name {
                    transcript.toolCounts[name, default: 0] += 1
                }
            default:
                continue
            }
        }
        return transcript
    }

    private static func textLines(of jsonl: String) -> [String] {
        jsonl.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func userPrompt(from raw: String) -> String {
        let ns = raw as NSString
        var found: [String] = []
        userQueryPattern.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let range = match?.range(at: 1) else { return }
            let value = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { found.append(value) }
        }
        return found.joined(separator: "\n\n")
    }

    private static func assistantText(from raw: String) -> String {
        let ns = raw as NSString
        let cleaned = injectedPattern.stringByReplacingMatches(
            in: raw,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
        return cleaned
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !toolNoisePrefixes.contains { trimmed.hasPrefix($0) }
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 导出

    static func markdown(session: WorkSession, transcript: Transcript) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        lines.append("# \(session.displayTitle)")
        lines.append("")
        lines.append("- 会话 ID：`\(session.id)`")
        lines.append("- 归属账号：`\(session.userID)`")
        lines.append("- 工作目录：`\(session.cwd)`")
        lines.append("- 创建：\(f.string(from: session.createdAt))")
        lines.append("- 更新：\(f.string(from: session.updatedAt))")
        lines.append("- 传输：\(session.transport)")
        lines.append("")
        lines.append("---")
        lines.append("")

        guard !transcript.isMissing else {
            lines.append("> 未找到正文文件。")
            return lines.joined(separator: "\n") + "\n"
        }

        for turn in transcript.turns {
            lines.append("### \(turn.speaker == .user ? "用户" : "助手")")
            lines.append("")
            lines.append(turn.text)
            lines.append("")
        }

        if !transcript.toolSummary.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append("工具调用：\(transcript.toolSummary)")
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func exportFilename(for session: WorkSession) -> String {
        let title = session.displayTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let trimmed = String(title.prefix(40))
        return "\(session.shortID)-\(trimmed.isEmpty ? "untitled" : trimmed).md"
    }
}

/// 只取需要的字段，避免整条记录里的 providerData 等大对象参与解码。
private struct TranscriptEntry: Decodable {
    struct Part: Decodable {
        let type: String
        let text: String

        enum CodingKeys: String, CodingKey {
            case type, text
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        }
    }

    let type: String
    let role: String?
    let content: [Part]?
    let name: String?
}
