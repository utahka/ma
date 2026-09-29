import AppKit

/// Markdown の文字列はそのままに、文字属性だけでライブプレビューを表現する。
/// 当面は正規表現で行ごとに判定する。必要になったら swift-markdown の構文木に置き換える
@MainActor
struct MarkdownStyler {
    private let bodyFont = NSFont.systemFont(ofSize: 15)
    private let monoFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    private let hiddenFont = NSFont.systemFont(ofSize: 0.01)
    private let headingSizes: [CGFloat] = [0, 26, 22, 19, 17, 15, 15]
    private let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style
    }()

    private let fence = Self.regex(#"^(```|~~~)"#)
    private let heading = Self.regex(#"^(#{1,6})[ \t]+"#)
    private let quote = Self.regex(#"^>[ \t]?"#)
    private let listMarker = Self.regex(#"^[ \t]*([-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    private let rule = Self.regex(#"^(-{3,}|\*{3,}|_{3,})[ \t]*$"#)
    private let inlineCode = Self.regex(#"`[^`\n]+`"#)
    private let bold = Self.regex(#"(\*\*|__)(?=\S)[^\n]+?(?<=\S)\1"#)
    private let italic = Self.regex(#"(?<![*\w])([*_])(?=\S)[^*_\n]+?(?<=\S)\1(?![*\w])"#)
    private let strike = Self.regex(#"~~(?=\S)[^\n]+?(?<=\S)~~"#)
    private let wikiLink = Self.regex(#"\[\[([^\]|\n]+)(\|[^\]\n]+)?\]\]"#)
    private let link = Self.regex(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    private let calloutHeader = Self.regex(#"^>[ \t]?\[!([A-Za-z-]+)\]([+-])?[ \t]*(.*)$"#)
    private let tableRow = Self.regex(#"^[ \t]*\|"#)
    private let tableSeparator = Self.regex(#"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)
    private let cellReplacements: [(NSRegularExpression, String)] = [
        (Self.regex(#"\[\[[^\]|]+\|([^\]]+)\]\]"#), "$1"),
        (Self.regex(#"\[\[([^\]]+)\]\]"#), "$1"),
        (Self.regex(#"\[([^\]]+)\]\([^)]+\)"#), "$1"),
        (Self.regex(#"\*\*|__|~~|`"#), ""),
    ]

    private struct Line {
        let full: NSRange
        let content: NSRange
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle]
    }

    func apply(to storage: NSTextStorage, activeRange: NSRange) {
        let text = storage.string
        let string = text as NSString
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: string.length))

        var lines: [Line] = []
        var position = 0
        while position < string.length {
            let lineRange = string.lineRange(for: NSRange(location: position, length: 0))
            position = NSMaxRange(lineRange)
            lines.append(Line(full: lineRange, content: contentRange(of: lineRange, in: string)))
        }
        func isActive(_ range: NSRange) -> Bool { NSIntersectionRange(range, activeRange).length > 0 }

        var inFence = false
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let active = isActive(line.full)

            if fence.firstMatch(in: text, range: line.content) != nil {
                storage.addAttributes([.font: monoFont, .foregroundColor: NSColor.tertiaryLabelColor], range: line.content)
                inFence.toggle()
                index += 1
                continue
            }
            if inFence {
                storage.addAttributes([.font: monoFont, .backgroundColor: NSColor.quaternarySystemFill], range: line.content)
                index += 1
                continue
            }
            if let end = tableEnd(from: index, in: lines, text: text) {
                let block = Array(lines[index..<end])
                if isActive(block.first!.full.union(block.last!.full)) {
                    styleRawTable(block, text: text, in: storage)
                } else {
                    styleRenderedTable(block, text: text, in: storage)
                }
                index = end
                continue
            }
            if quote.firstMatch(in: text, range: line.content) != nil {
                var end = index + 1
                while end < lines.count, quote.firstMatch(in: text, range: lines[end].content) != nil { end += 1 }
                let block = Array(lines[index..<end])
                styleQuoteBlock(block, text: text, in: storage, blockActive: isActive(block.first!.full.union(block.last!.full)), isActive: isActive)
                index = end
                continue
            }
            styleBlock(text, line: line.content, in: storage, active: active)
            styleInline(text, line: line.content, in: storage, active: active)
            index += 1
        }
    }

    // MARK: - 表

    /// `index` の行から表が始まるなら、表の直後の行番号を返す。見出し行の次に区切り行（|---|）が必要
    private func tableEnd(from index: Int, in lines: [Line], text: String) -> Int? {
        guard index + 1 < lines.count,
              tableRow.firstMatch(in: text, range: lines[index].content) != nil,
              tableSeparator.firstMatch(in: text, range: lines[index + 1].content) != nil
        else { return nil }
        var end = index + 2
        while end < lines.count, tableRow.firstMatch(in: text, range: lines[end].content) != nil { end += 1 }
        return end
    }

    /// カーソルが表の中にあるときは、ソースを等幅で表示する
    private func styleRawTable(_ block: [Line], text: String, in storage: NSTextStorage) {
        for line in block {
            storage.addAttribute(.font, value: monoFont, range: line.content)
        }
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: block[1].content)
    }

    /// カーソルが表の外にあるときは、ソースを透明にして、レイアウトフラグメントに罫線とセルを描かせる
    private func styleRenderedTable(_ block: [Line], text: String, in storage: NSTextStorage) {
        let string = text as NSString
        let rows = block.map { tableCells(string.substring(with: $0.content)) }
        let alignments = rows[1].map { cell -> NSTextAlignment in
            let separator = cell.trimmingCharacters(in: .whitespaces)
            switch (separator.hasPrefix(":"), separator.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .right
            default: return .left
            }
        }
        let columnCount = rows[0].count
        var widths = [CGFloat](repeating: 48, count: columnCount)
        // 揃えの `:` も含めた文字数を数える（書き出す側も `:` を含めた文字数で幅を表す）
        let dashCounts = rows[1].map { $0.trimmingCharacters(in: .whitespaces).count }
        if dashCounts.contains(where: { $0 > 3 }) {
            // 区切り行の `-` が 4 本以上ある列があれば、`-` の数を列幅として使う（ドラッグで変えた幅もここに保存される）
            for column in 0..<min(columnCount, dashCounts.count) {
                widths[column] = max(
                    TableLayout.minimumWidth,
                    CGFloat(dashCounts[column]) * TableLayout.dashWidth + TableRowDecoration.cellPadding * 2
                )
            }
        } else {
            for (rowIndex, row) in rows.enumerated() where rowIndex != 1 {
                let font = rowIndex == 0 ? TableRowDecoration.headerFont : TableRowDecoration.bodyFont
                for (column, cell) in row.prefix(columnCount).enumerated() {
                    let width = (plainText(cell) as NSString).size(withAttributes: [.font: font]).width
                    widths[column] = max(widths[column], ceil(width) + TableRowDecoration.cellPadding * 2)
                }
            }
        }
        let layout = TableLayout(
            columnWidths: widths, alignments: alignments,
            separatorRange: block[1].content, tableRange: block.first!.full.union(block.last!.full)
        )

        for (rowIndex, line) in block.enumerated() {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byClipping
            let kind: TableRowDecoration.Kind
            if rowIndex == 1 {
                kind = .separator
                style.minimumLineHeight = 0.01
                style.maximumLineHeight = 0.01
                storage.addAttribute(.font, value: hiddenFont, range: line.full)
            } else {
                kind = rowIndex == 0 ? .header : .body
                style.minimumLineHeight = TableRowDecoration.rowHeight
                style.maximumLineHeight = TableRowDecoration.rowHeight
            }
            let cells = rows[rowIndex].map(plainText)
            storage.addAttributes([
                .foregroundColor: NSColor.clear,
                .paragraphStyle: style,
                .maBlock: TableRowDecoration(kind: kind, cells: cells, layout: layout, isLast: rowIndex == block.count - 1),
            ], range: line.full)
        }
    }

    /// `| a | b |` をセルに分ける。`\|` はセル内の縦棒として扱う
    private func tableCells(_ row: String) -> [String] {
        var body = Substring(row.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") && !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var previous: Character?
        for character in body {
            if character == "|" && previous != "\\" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// セル内の簡単な記法を外して表示用の文字列にする
    private func plainText(_ cell: String) -> String {
        var result = cell.replacingOccurrences(of: "\\|", with: "|")
        for (regex, template) in cellReplacements {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: template
            )
        }
        return result
    }

    // MARK: - 引用とコールアウト

    private func styleQuoteBlock(
        _ block: [Line], text: String, in storage: NSTextStorage, blockActive: Bool, isActive: (NSRange) -> Bool
    ) {
        let header = calloutHeader.firstMatch(in: text, range: block[0].content)
        let string = text as NSString
        let callout = header.map { match -> CalloutStyle in
            let type = string.substring(with: match.range(at: 1)).lowercased()
            return CalloutStyle(type: type)
        }
        // [!note]- は、カーソルがコールアウトの外にあるあいだ本文をたたむ
        let folded = header.map { $0.range(at: 2).location != NSNotFound && string.substring(with: $0.range(at: 2)) == "-" } ?? false
        let collapsed = folded && !blockActive

        for (lineIndex, line) in block.enumerated() {
            let active = isActive(line.full)
            let isFirst = lineIndex == 0
            let isLast = lineIndex == block.count - 1 || (collapsed && isFirst)
            let style = NSMutableParagraphStyle()
            style.headIndent = 14
            style.firstLineHeadIndent = 14
            style.tailIndent = callout == nil ? 0 : -14
            style.lineSpacing = 2
            style.minimumLineHeight = 24
            // 枠の内側の上下の余白。段落の前後の間隔もフラグメントに含まれ、背景が塗られる
            if isFirst && callout != nil { style.paragraphSpacingBefore = 4 }
            if isLast && callout != nil { style.paragraphSpacing = 6 }

            if let header, isFirst, let callout {
                let title = header.range(at: 3)
                style.firstLineHeadIndent = 14 + 24
                marker(NSRange(location: line.content.location, length: title.location - line.content.location), in: storage, active: active)
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                    .foregroundColor: callout.color,
                ], range: title)
                styleInline(text, line: title, in: storage, active: active)
                let fallback = title.length == 0 && !active ? callout.defaultTitle : nil
                storage.addAttributes([
                    .paragraphStyle: style,
                    .maBlock: BoxDecoration(
                        color: callout.color, icon: callout.icon, fallbackTitle: fallback,
                        foldable: folded, collapsed: collapsed, isFirst: true, isLast: isLast
                    ),
                ], range: line.full)
                continue
            }
            if collapsed {
                style.minimumLineHeight = 0.01
                style.maximumLineHeight = 0.01
                style.lineSpacing = 0
                storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: style], range: line.full)
                continue
            }

            let prefix = quote.firstMatch(in: text, range: line.content)!.range
            let rest = NSRange(location: NSMaxRange(prefix), length: NSMaxRange(line.content) - NSMaxRange(prefix))
            if callout == nil {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: rest)
            }
            marker(prefix, in: storage, active: active)
            styleBlock(text, line: rest, in: storage, active: active)
            styleInline(text, line: rest, in: storage, active: active)
            storage.addAttributes([
                .paragraphStyle: style,
                .maBlock: callout.map {
                    BoxDecoration(color: $0.color, icon: nil, fallbackTitle: nil, foldable: false, collapsed: false, isFirst: isFirst, isLast: isLast)
                } ?? BoxDecoration.quote(isFirst: isFirst, isLast: isLast),
            ], range: line.full)
        }
    }

    private func styleBlock(_ text: String, line: NSRange, in storage: NSTextStorage, active: Bool) {
        if let match = heading.firstMatch(in: text, range: line) {
            let level = match.range(at: 1).length
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: headingSizes[level], weight: .bold), range: line)
            marker(match.range, in: storage, active: active)
        } else if let match = quote.firstMatch(in: text, range: line) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line)
            marker(match.range, in: storage, active: active)
        } else if rule.firstMatch(in: text, range: line) != nil {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: line)
        } else if let match = listMarker.firstMatch(in: text, range: line) {
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range(at: 1))
            if match.range(at: 2).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range(at: 2))
            }
        }
    }

    private func styleInline(_ text: String, line: NSRange, in storage: NSTextStorage, active: Bool) {
        // コードの中は他の記法として解釈しない
        var codeRanges: [NSRange] = []
        for match in inlineCode.matches(in: text, range: line) {
            codeRanges.append(match.range)
            storage.addAttributes([.font: monoFont, .backgroundColor: NSColor.quaternarySystemFill], range: match.range)
            wrapMarkers(match.range, length: 1, in: storage, active: active)
        }
        func matches(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
            regex.matches(in: text, range: line).filter { match in
                !codeRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
            }
        }

        for match in matches(bold) {
            addTrait(.boldFontMask, range: match.range, in: storage)
            wrapMarkers(match.range, length: 2, in: storage, active: active)
        }
        for match in matches(italic) {
            addTrait(.italicFontMask, range: match.range, in: storage)
            wrapMarkers(match.range, length: 1, in: storage, active: active)
        }
        for match in matches(strike) {
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: match.range)
            wrapMarkers(match.range, length: 2, in: storage, active: active)
        }
        for match in matches(wikiLink) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range)
            wrapMarkers(match.range, length: 2, in: storage, active: active)
            // [[ノート名|表示名]] は表示名だけを見せる
            let alias = match.range(at: 2)
            if alias.location != NSNotFound {
                let target = NSRange(location: match.range.location + 2, length: alias.location - match.range.location - 1)
                marker(target, in: storage, active: active)
            }
        }
        for match in matches(link) {
            let label = match.range(at: 1)
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: label)
            marker(NSRange(location: match.range.location, length: 1), in: storage, active: active)
            marker(NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)), in: storage, active: active)
        }
    }

    /// 記法の記号。カーソル行では薄く表示し、それ以外では幅ゼロ・透明にして隠す
    private func marker(_ range: NSRange, in storage: NSTextStorage, active: Bool) {
        if active {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        } else {
            storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: range)
        }
    }

    private func wrapMarkers(_ range: NSRange, length: Int, in storage: NSTextStorage, active: Bool) {
        marker(NSRange(location: range.location, length: length), in: storage, active: active)
        marker(NSRange(location: NSMaxRange(range) - length, length: length), in: storage, active: active)
    }

    private func addTrait(_ trait: NSFontTraitMask, range: NSRange, in storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? bodyFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
        }
    }

    private func contentRange(of lineRange: NSRange, in string: NSString) -> NSRange {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let character = string.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        return NSRange(location: lineRange.location, length: end - lineRange.location)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}
