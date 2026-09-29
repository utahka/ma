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
    private let lineBreakTag = Self.regex(#"<br\s*/?>"#, options: [.caseInsensitive])

    private struct Line {
        let full: NSRange
        let content: NSRange
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle]
    }

    /// 装飾をかけ直し、文書中の表を返す。`availableWidth` は本文の幅で、表が収まらないときの縮小に使う。
    /// `sourceMode` では装飾を外し、等幅フォントで Markdown をそのまま見せる
    @discardableResult
    func apply(to storage: NSTextStorage, activeRange: NSRange, availableWidth: CGFloat, sourceMode: Bool) -> [TableLayout] {
        let text = storage.string
        let string = text as NSString
        storage.beginEditing()
        defer { storage.endEditing() }
        let whole = NSRange(location: 0, length: string.length)
        storage.setAttributes(baseAttributes, range: whole)
        if sourceMode {
            storage.addAttribute(.font, value: monoFont, range: whole)
            return []
        }

        var lines: [Line] = []
        var position = 0
        while position < string.length {
            let lineRange = string.lineRange(for: NSRange(location: position, length: 0))
            position = NSMaxRange(lineRange)
            lines.append(Line(full: lineRange, content: contentRange(of: lineRange, in: string)))
        }
        func isActive(_ range: NSRange) -> Bool { NSIntersectionRange(range, activeRange).length > 0 }

        var tables: [TableLayout] = []
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
                tables.append(styleTable(block, text: text, in: storage, availableWidth: availableWidth, isActive: isActive))
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
        return tables
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

    /// 表を、元の文字のまま表の形に並べる。縦棒とセルの前後の空白は幅ゼロにして隠し、
    /// 字間（kern）を足して各セルの文字を列の位置まで送る。罫線と見出しの背景はレイアウトフラグメントが描く。
    /// 文字を描き直さないので、カーソルを入れても表の形のまま通常のテキストとして編集できる
    private func styleTable(
        _ block: [Line], text: String, in storage: NSTextStorage, availableWidth: CGFloat, isActive: (NSRange) -> Bool
    ) -> TableLayout {
        let string = text as NSString
        let padding = TableRowDecoration.cellPadding
        let separatorCells = tableSegments(block[1].content, in: string).map { string.substring(with: $0).trimmingCharacters(in: .whitespaces) }
        let alignments = separatorCells.map { cell -> NSTextAlignment in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .right
            default: return .left
            }
        }
        // 見出し行と本文の行。区切り行（index 1）は含めない
        let rows = block.enumerated().filter { $0.offset != 1 }.map { offset, line in
            (line: line, isHeader: offset == 0, cells: tableSegments(line.content, in: string))
        }
        let columnCount = rows[0].cells.count

        // 1. 文字の装飾。セルの中身だけを見せ、縦棒と前後の空白は幅ゼロにする
        var textRanges: [[NSRange]] = []
        for row in rows {
            let active = isActive(row.line.full)
            storage.addAttribute(.font, value: row.isHeader ? TableRowDecoration.headerFont : TableRowDecoration.bodyFont, range: row.line.content)
            let cells = row.cells.map { trimmed($0, in: string) }
            textRanges.append(cells)
            var visible = IndexSet()
            for (column, cell) in cells.enumerated() where cell.length > 0 {
                if column < columnCount { visible.insert(integersIn: cell.location..<NSMaxRange(cell)) }
                styleInline(text, line: cell, in: storage, active: active)
                // <br> はセル内の改行として「↵」で示す
                for match in lineBreakTag.matches(in: text, range: cell) {
                    let last = NSRange(location: NSMaxRange(match.range) - 1, length: 1)
                    storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear],
                                          range: NSRange(location: match.range.location, length: match.range.length - 1))
                    // 「>」より幅のある「↵」が隣の文字に重ならないよう、字間で幅を足す
                    storage.addAttributes([.foregroundColor: NSColor.clear, .kern: 8,
                                           .maReplacement: Replacement("↵", color: .tertiaryLabelColor)], range: last)
                }
            }
            for index in row.line.content.location..<NSMaxRange(row.line.content) where !visible.contains(index) {
                storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: index, length: 1))
            }
        }
        storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: block[1].full)

        // 2. 列幅。区切り行に `-` が 4 本以上ある列があれば幅の指定ありとみなし、なければ中身に合わせる
        let measured = textRanges.map { row in
            row.map { $0.length > 0 ? ceil(storage.attributedSubstring(from: $0).size().width) : 0 }
        }
        var widths = [CGFloat](repeating: 48, count: columnCount)
        if separatorCells.contains(where: { $0.filter { $0 == "-" }.count > 3 }) {
            // 幅は揃えの `:` も含めた文字数で表す（ドラッグで変えた幅もこの形で保存される）
            for (column, cell) in separatorCells.prefix(columnCount).enumerated() {
                widths[column] = max(TableLayout.minimumWidth, CGFloat(cell.count) * TableLayout.dashWidth + padding * 2)
            }
        } else {
            // 自動幅は、<br> で区切った各行のうち最も長い行に合わせる
            for row in textRanges {
                for (column, content) in row.prefix(columnCount).enumerated() where content.length > 0 {
                    widths[column] = max(widths[column], widestLine(content, in: storage, text: text) + padding * 2)
                }
            }
        }
        let layout = TableLayout(
            columnWidths: widths, alignments: alignments, separatorRange: block[1].content,
            rows: rows.map { $0.cells }, tableRange: block.first!.full.union(block.last!.full)
        )
        let drawn = layout.scaledWidths(available: availableWidth).widths

        // 3. 字間でセルの文字を列の位置へ送る
        let font = TableRowDecoration.bodyFont
        // 日本語の文字はベースラインの下に深く入るので、計算上の中央より 1pt 上げる
        let lift = (TableRowDecoration.rowHeight - (font.ascender - font.descender)) / 2 + 1
        for (rowIndex, row) in rows.enumerated() {
            var kerns: [Int: CGFloat] = [:]
            var indent: CGFloat = 0
            let lineStart = row.line.content.location
            for column in 0..<min(columnCount, row.cells.count) {
                let cell = row.cells[column]
                let content = textRanges[rowIndex][column]
                let width = measured[rowIndex][column]
                let left: CGFloat
                switch column < alignments.count ? alignments[column] : .left {
                case .center: left = max(0, (drawn[column] - width) / 2)
                case .right: left = max(0, drawn[column] - padding - width)
                default: left = padding
                }
                let right = max(0, drawn[column] - left - width)
                // 左の余白はセルの文字の直前の文字（隠した縦棒か空白）に、右の余白はセルの最後の文字に足す
                if content.location > lineStart { kerns[content.location - 1, default: 0] += left } else { indent += left }
                let last = cell.length > 0 ? NSMaxRange(cell) - 1 : content.location - 1
                if last >= lineStart { kerns[last, default: 0] += right }
            }
            // カーソルのない行で、<br> や列幅に収まらない文字があるセルがあれば、フラグメントが改行・折り返して描く。
            // カーソルのある行は、元の文字を1行に並べたまま編集させる
            var cellTexts: [NSAttributedString]?
            var height = TableRowDecoration.rowHeight
            let wraps = (0..<min(columnCount, row.cells.count)).contains { column in
                let content = textRanges[rowIndex][column]
                return content.length > 0 && (lineBreakTag.firstMatch(in: text, range: content) != nil
                    || measured[rowIndex][column] > drawn[column] - padding * 2)
            }
            if !isActive(row.line.full) && wraps {
                let texts = (0..<columnCount).map { column -> NSAttributedString in
                    guard column < textRanges[rowIndex].count, textRanges[rowIndex][column].length > 0 else { return NSAttributedString() }
                    return cellText(textRanges[rowIndex][column], alignment: column < alignments.count ? alignments[column] : .left,
                                    in: storage, text: text)
                }
                let tallest = texts.enumerated().map { column, cell in
                    cell.boundingRect(with: CGSize(width: max(1, drawn[column] - padding * 2), height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).height
                }.max() ?? 0
                // 折り返した文字の計測値は描いた高さより少し小さく出るので、下の余白を上と揃えるために足す
                height = max(height, ceil(tallest) + TableRowDecoration.verticalPadding * 2 + 4)
                cellTexts = texts
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: row.line.content)
                storage.removeAttribute(.maReplacement, range: row.line.content)
            }
            for (index, kern) in kerns {
                storage.addAttribute(.kern, value: kern, range: NSRange(location: index, length: 1))
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byClipping
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            style.firstLineHeadIndent = indent
            storage.addAttributes([
                .paragraphStyle: style,
                // 行高を固定すると余りは文字の上に入るので、ベースラインを上げて縦中央に置く
                .baselineOffset: lift,
                .maBlock: TableRowDecoration(kind: row.isHeader ? .header : .body, layout: layout,
                                             isLast: rowIndex == rows.count - 1, cellTexts: cellTexts),
            ], range: row.line.full)
        }
        let separatorStyle = NSMutableParagraphStyle()
        separatorStyle.minimumLineHeight = 0.01
        separatorStyle.maximumLineHeight = 0.01
        storage.addAttributes([
            .paragraphStyle: separatorStyle,
            .maBlock: TableRowDecoration(kind: .separator, layout: layout, isLast: false),
        ], range: block[1].full)
        return layout
    }

    /// セルの文字を <br> で区切ったときの、最も長い行の幅
    private func widestLine(_ range: NSRange, in storage: NSTextStorage, text: String) -> CGFloat {
        var widest: CGFloat = 0
        var start = range.location
        for match in lineBreakTag.matches(in: text, range: range) + [nil] {
            let end = match?.range.location ?? NSMaxRange(range)
            if end > start {
                widest = max(widest, ceil(storage.attributedSubstring(from: NSRange(location: start, length: end - start)).size().width))
            }
            if let match { start = NSMaxRange(match.range) }
        }
        return widest
    }

    /// フラグメントが描くセルの文字。装飾済みの文字をもとに、<br> を改行に置き換える
    private func cellText(_ range: NSRange, alignment: NSTextAlignment, in storage: NSTextStorage, text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        for key: NSAttributedString.Key in [.kern, .maReplacement, .baselineOffset, .paragraphStyle] {
            result.removeAttribute(key, range: NSRange(location: 0, length: result.length))
        }
        // 改行文字は本文の文字の大きさにする（置き換える前の「<br>」は隠すために極小のフォントになっている）
        for match in lineBreakTag.matches(in: text, range: range).reversed() {
            result.replaceCharacters(
                in: NSRange(location: match.range.location - range.location, length: match.range.length),
                with: NSAttributedString(string: "\n", attributes: [.font: TableRowDecoration.bodyFont])
            )
        }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineSpacing = 2
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// 行をセルに分け、各セルの範囲（縦棒の間。前後の空白を含む）を返す。`\|` はセル内の縦棒として扱う
    private func tableSegments(_ content: NSRange, in string: NSString) -> [NSRange] {
        let end = NSMaxRange(content)
        var index = content.location
        while index < end, isBlank(string.character(at: index)) { index += 1 }
        if index < end, string.character(at: index) == 0x7C { index += 1 }
        var segments: [NSRange] = []
        var start = index
        while index < end {
            let character = string.character(at: index)
            if character == 0x5C { index += 2; continue }
            if character == 0x7C {
                segments.append(NSRange(location: start, length: index - start))
                start = index + 1
            }
            index += 1
        }
        let tail = NSRange(location: start, length: max(0, end - start))
        if trimmed(tail, in: string).length > 0 { segments.append(tail) }
        return segments
    }

    /// セルの前後の空白を除いた範囲。空のセルは、縦棒の直後の空白の後ろ（入力が入る位置）を長さ 0 で返す
    private func trimmed(_ range: NSRange, in string: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isBlank(string.character(at: start)) { start += 1 }
        while end > start, isBlank(string.character(at: end - 1)) { end -= 1 }
        if start == end { return NSRange(location: range.location + min(1, range.length), length: 0) }
        return NSRange(location: start, length: end - start)
    }

    private func isBlank(_ character: unichar) -> Bool { character == 0x20 || character == 0x09 }

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
            if isLast && callout != nil { style.paragraphSpacing = 12 }

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
            let checkbox = match.range(at: 2)
            guard checkbox.location != NSNotFound else {
                let bullet = match.range(at: 1)
                if bullet.length == 1 {
                    // `-` `*` `+` は中黒で表示する
                    storage.addAttributes([.foregroundColor: NSColor.clear,
                                           .maReplacement: Replacement("・", color: .secondaryLabelColor)], range: bullet)
                } else {
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: bullet)
                }
                return
            }
            // タスクは箇条書きの記号を隠し、`[ ]` を透明にしてその位置にチェックボックスを描く
            marker(match.range(at: 1), in: storage, active: active)
            let brackets = NSRange(location: checkbox.location, length: 3)
            let checked = (text as NSString).character(at: brackets.location + 1) != 0x20
            storage.addAttributes([.foregroundColor: NSColor.clear, .maCheckbox: checked], range: brackets)
            if checked {
                let rest = NSRange(location: NSMaxRange(checkbox), length: NSMaxRange(line) - NSMaxRange(checkbox))
                storage.addAttributes([
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ], range: rest)
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

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}
