import SwiftUI

/// 会话正文里的 markdown 必须自己切块渲染。
///
/// `Text(AttributedString(markdown:))` 遇到 GFM 表格时无法还原块级结构，SwiftUI 会把
/// 整段退回等宽代码样式——本该是正常段落的中文说明，连同后面的表格一起变成一坨代码。
/// 行内的粗体、行内代码是安全的，所以只把它们交给 AttributedString。
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Inline(text: text, size: level <= 2 ? 14 : 13, weight: .semibold)
        case .paragraph(let text):
            Inline(text: text)
        case .code(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Inline(text: item)
                    }
                }
            }
        case .table(let rows):
            table(rows)
        }
    }

    /// 表格用等宽列的横排实现，比 Grid 稳：单元格长短不一时也不会把某列挤没。
    private func table(_ rows: [[String]]) -> some View {
        let columns = max(rows.map(\.count).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(0..<columns, id: \.self) { column in
                        Inline(text: column < row.count ? row[column] : "",
                               weight: index == 0 ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 7)
                .background(index == 0 ? Color.primary.opacity(0.07) : Color.clear)
                if index < rows.count - 1 {
                    Divider().opacity(0.35)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
    }
}

/// 单行内的 markdown：粗体、斜体、行内代码。字体由调用方给，保证块与块的层级清楚。
private struct Inline: View {
    let text: String
    var size: CGFloat = 12
    var weight: Font.Weight = .regular

    var body: some View {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            .font(.system(size: size, weight: weight))
            .textSelection(.enabled)
    }
}

enum MarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case code(String)
    case bullet([String])
    case table([[String]])

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var pending: [String] = []
        var index = 0

        func flush() {
            let joined = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            pending = []
        }

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)

            if isFence(line) {
                flush()
                index += 1
                var body: [String] = []
                while index < lines.count, !isFence(lines[index].trimmingCharacters(in: .whitespaces)) {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }   // 收尾围栏
                blocks.append(.code(body.joined(separator: "\n")))
                continue
            }

            let hashes = line.prefix(while: { $0 == "#" }).count
            if hashes > 0, hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") {
                flush()
                blocks.append(.heading(hashes, String(line.dropFirst(hashes))
                    .trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            // 分隔线没有信息量，别当正文显示成一行「---」
            if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                index += 1
                continue
            }

            if line.contains("|"), index + 1 < lines.count, isTableDivider(lines[index + 1]) {
                flush()
                var rows: [[String]] = [cells(line)]
                index += 2
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard next.contains("|"), !isTableDivider(next) else { break }
                    rows.append(cells(next))
                    index += 1
                }
                blocks.append(.table(rows))
                continue
            }

            if let item = listItem(line) {
                flush()
                var items = [item]
                index += 1
                while index < lines.count,
                      let more = listItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(more)
                    index += 1
                }
                blocks.append(.bullet(items))
                continue
            }

            pending.append(lines[index])
            index += 1
        }
        flush()
        return blocks
    }

    private static func isFence(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return t.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        // 有序列表只认行首的「数字. 」。若用 firstIndex(of: ".") 去找，
        // `**1. 有一处改动**` 这种加粗编号会被误判成列表，还会吃掉开头的 `**`。
        var cursor = line.startIndex
        var digits = 0
        while cursor < line.endIndex, line[cursor].isNumber, digits < 3 {
            cursor = line.index(after: cursor)
            digits += 1
        }
        guard digits > 0, cursor < line.endIndex, line[cursor] == "." else { return nil }
        let space = line.index(after: cursor)
        guard space < line.endIndex, line[space] == " " else { return nil }
        return String(line[line.index(after: space)...])
    }
}
