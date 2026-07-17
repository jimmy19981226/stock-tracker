import SwiftUI

/// Renders the assistant's Markdown the way Claude's chat does: headings, bold/
/// italic, inline code, fenced code blocks, bullet/numbered lists, blockquotes
/// and rules — block by block, with sensible spacing. Inline styling uses
/// AttributedString's Markdown parser; block structure is parsed here.
struct MarkdownText: View {
    let markdown: String
    var textColor: Color = Theme.primaryText
    /// Claude-style serif reading voice for body text and headings. Colors and
    /// code/table styling are unaffected — this is typography only.
    var serif = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    // MARK: - Rendering

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(.system(size: headingSize(level), weight: .bold,
                              design: serif ? .serif : .rounded))
                .foregroundStyle(textColor)
                .padding(.top, level <= 2 ? 2 : 0)

        case let .paragraph(lines):
            multiline(lines)
                .font(bodyFont)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)

        case let .bullet(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.accent)
                        inline(item).foregroundStyle(textColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(bodyFont)
                }
            }

        case let .ordered(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).")
                            .foregroundStyle(Theme.accent)
                            .monospacedDigit()
                        inline(item).foregroundStyle(textColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(bodyFont)
                }
            }

        case let .code(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(textColor)
                    .padding(12)
            }
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )

        case let .quote(lines):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent.opacity(0.6))
                    .frame(width: 3)
                multiline(lines)
                    .font(bodyFont)
                    .foregroundStyle(Theme.secondaryText)
            }

        case .rule:
            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.vertical, 2)

        case let .table(header, rows):
            // GFM table → a real grid (wide tables scroll horizontally).
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            inline(cell)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell)
                                    .font(.footnote)
                                    .foregroundStyle(textColor)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(Theme.bg.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
        }
    }

    /// Body text voice: 15pt serif in Claude mode, .subheadline otherwise.
    private var bodyFont: Font {
        serif ? .system(size: 15, design: .serif) : .subheadline
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 21
        case 2: return 18
        case 3: return 16
        default: return 15
        }
    }

    /// One Markdown line → styled Text (inline bold/italic/code/links).
    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: s, options: opts) {
            return Text(attr)
        }
        return Text(s)
    }

    /// Multiple soft-wrapped lines joined with real line breaks.
    private func multiline(_ lines: [String]) -> Text {
        var t = Text("")
        for (i, line) in lines.enumerated() {
            if i > 0 { t = t + Text("\n") }
            t = t + inline(line)
        }
        return t
    }

    // MARK: - Block parsing

    enum Block {
        case heading(Int, String)
        case paragraph([String])
        case bullet([String])
        case ordered([String])
        case code(String)
        case quote([String])
        case rule
        case table([String], [[String]])  // header cells, data rows
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = shortenLinkLabels(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var i = 0
        var paragraph: [String] = []
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph)); paragraph = [] }
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if line.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1 // skip closing fence (or EOF)
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if line.isEmpty { flushParagraph(); i += 1; continue }

            // Horizontal rule
            if line == "---" || line == "***" || line == "___" {
                flushParagraph(); blocks.append(.rule); i += 1; continue
            }

            // Heading
            if let h = headingMatch(line) {
                flushParagraph(); blocks.append(.heading(h.0, h.1)); i += 1; continue
            }

            // Blockquote (consecutive)
            if line.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    quote.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote)); continue
            }

            // Bullet list (consecutive)
            if isBullet(line) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripBullet(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.bullet(items)); continue
            }

            // Ordered list (consecutive)
            if isOrdered(line) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isOrdered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripOrdered(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.ordered(items)); continue
            }

            // GFM table: `| a | b |` header, `|---|---|` separator, data rows.
            if isTableRow(line), i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let header = tableCells(line)
                i += 2 // skip header + separator
                var rows: [[String]] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isTableRow(l) else { break }
                    // Pad/trim to the header width so Grid rows line up.
                    var cells = tableCells(l)
                    while cells.count < header.count { cells.append("") }
                    rows.append(Array(cells.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header, rows))
                continue
            }

            // Plain paragraph line
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.dropFirst().contains("|")
    }

    /// `|---|:---:|` — only pipes, dashes, colons and spaces, with a dash.
    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|"), line.contains("-") else { return false }
        let allowed = Set("|-: ")
        return line.allSatisfy { allowed.contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("|") { l.removeFirst() }
        if l.hasSuffix("|") { l.removeLast() }
        return l.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Replace `[label](url)` whose label is itself a long URL with the URL's
    /// host, so source citations show "cnbc.com" instead of a giant redirect URL
    /// that overflows the bubble. The tappable link target is preserved.
    static func shortenLinkLabels(_ text: String) -> String {
        let pattern = #"\[([^\]]*)\]\(([^)\s]+)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let label = ns.substring(with: m.range(at: 1))
            let url = ns.substring(with: m.range(at: 2))
            let needsShorten = label.isEmpty
                || label.lowercased().hasPrefix("http")
                || label.count > 40
            let display = needsShorten ? host(of: url) : label
            result += "[\(display)](\(url))"
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func host(of url: String) -> String {
        var s = url
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s.isEmpty ? "link" : s
    }

    private static func headingMatch(_ line: String) -> (Int, String)? {
        var level = 0
        for ch in line { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }
    private static func stripBullet(_ line: String) -> String {
        String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    private static func isOrdered(_ line: String) -> Bool {
        let parts = line.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[0].allSatisfy(\.isNumber) && parts[1].hasPrefix(" ")
    }
    private static func stripOrdered(_ line: String) -> String {
        guard let dot = line.firstIndex(of: ".") else { return line }
        return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
    }
}
