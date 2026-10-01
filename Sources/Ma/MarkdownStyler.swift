import AppKit

/// Markdown の文字列はそのままに、文字属性だけでライブプレビューを表現する。
/// 当面は正規表現で行ごとに判定する。必要になったら swift-markdown の構文木に置き換える
@MainActor
struct MarkdownStyler {
    private let bodyFont = NSFont.systemFont(ofSize: 15)
    private let monoFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    private let hiddenFont = NSFont.systemFont(ofSize: 0.01)
    /// チェックボックスの下に隠す `[ ]` のフォント
    private let checkboxFont = NSFont(name: "Helvetica", size: 15) ?? NSFont.systemFont(ofSize: 15)
    /// 箇条書きの1段の幅（タブ1つ、または空白2つ）
    private let listIndentStep: CGFloat = 28
    private var spaceKern: CGFloat {
        listIndentStep / 2 - (" " as NSString).size(withAttributes: [.font: bodyFont]).width
    }
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
    /// Obsidian のハイライト `==文字==`。本文に `==` を含めると、隣のハイライトとの間まで巻き込む
    private let highlight = Self.regex(#"==(?=\S)(?:(?!==)[^\n])+?(?<=\S)=="#)
    private let wikiLink = Self.regex(#"\[\[([^\]|\n]+)(\|[^\]\n]+)?\]\]"#)
    private let link = Self.regex(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    private let calloutHeader = Self.regex(#"^>[ \t]?\[!([A-Za-z-]+)\]([+-])?[ \t]*(.*)$"#)
    /// トグルの見出し行。1 は `+`/`-`、2 はタイトル
    private let toggleHeader = Self.regex(#"^>[ \t]?\[!toggle\]([+-])?[ \t]*(.*)$"#, options: [.caseInsensitive])
    /// コールアウトのタイトルの先頭の `[ ]` `[-]` `[x]`。1 は括弧の中の文字
    private let calloutTitleCheckbox = Self.regex(#"^\[([ xX-])\](?=[ \t]|$)"#)
    private let tableRow = Self.regex(#"^[ \t]*\|"#)
    private let tableSeparator = Self.regex(#"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)
    private let lineBreakTag = Self.regex(#"<br\s*/?>"#, options: [.caseInsensitive])
    /// `==選択した文字==<!-- AI: コメント -->`。1 は選んだ文字、2 はコメント、3 は `<!-- … -->` 全体
    private let aiComment = Self.regex(#"==(?=\S)((?:(?!==)[^\n])+?)(?<=\S)==(<!--\s*AI:\s*([^\n]*?)\s*-->)"#)

    private struct Line {
        let full: NSRange
        let content: NSRange
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.maText, .paragraphStyle: paragraphStyle]
    }

    /// 装飾をかけ直し、文書中の表を返す。`availableWidth` は本文の幅で、表が収まらないときの縮小に使う。
    /// `sourceMode` では装飾を外し、等幅フォントで Markdown をそのまま見せる。
    /// `draggedWidths` は列幅をドラッグ中の表の幅。区切り行の位置で表を特定し、区切り行から読んだ幅の代わりに使う。
    /// `frontmatter` の範囲は文字を隠し、最初の行の高さを `height` にして、そこにプロパティ欄を重ねられるようにする。
    /// `calloutIcons` が false ならコールアウトのタイトルの左のアイコンを描かない。
    /// `flippedCallouts` は開閉の印で、ファイルの `-`/`+` と逆の状態にした見出し行の先頭。
    /// `[!note]-` はカーソルが外にあっても開いたままにし、トグル（`[!toggle]`）は開いているものをたたむ。
    /// `selection` は選択範囲。表の1つのセルに収まっていれば、そのセルを表の形のまま編集できるように並べる
    @discardableResult
    func apply(
        to storage: NSTextStorage, activeRange: NSRange, availableWidth: CGFloat, sourceMode: Bool,
        selection: NSRange? = nil,
        draggedWidths: (separator: Int, widths: [CGFloat])? = nil,
        frontmatter: (range: NSRange, height: CGFloat)? = nil,
        calloutIcons: Bool = true, flippedCallouts: Set<Int> = []
    ) -> [TableLayout] {
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

        var index = 0
        if let frontmatter {
            let hidden = lines.prefix { NSMaxRange($0.full) <= NSMaxRange(frontmatter.range) }
            for (offset, line) in hidden.enumerated() {
                let height = offset == 0 ? frontmatter.height : 0.01
                let style = NSMutableParagraphStyle()
                style.minimumLineHeight = height
                style.maximumLineHeight = height
                storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: style], range: line.full)
            }
            index = hidden.count
        }
        var context = Context(text: text, storage: storage, isActive: isActive, draggedWidths: draggedWidths, selection: selection,
                              calloutIcons: calloutIcons, flippedCallouts: flippedCallouts)
        styleLines(Array(lines[index...]), availableWidth: availableWidth, context: &context)
        return context.tables
    }

    /// 行のまとまりを装飾するときに共通で使うもの
    private struct Context {
        let text: String
        let storage: NSTextStorage
        let isActive: (NSRange) -> Bool
        let draggedWidths: (separator: Int, widths: [CGFloat])?
        let selection: NSRange?
        let calloutIcons: Bool
        let flippedCallouts: Set<Int>
        var tables: [TableLayout] = []
    }

    /// 行を順に装飾する。トグルの中身は `>` を1段外した行として、ここに戻して装飾する
    private func styleLines(_ lines: [Line], availableWidth: CGFloat, context: inout Context) {
        let text = context.text
        let string = text as NSString
        let storage = context.storage
        let isActive = context.isActive
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let active = isActive(line.full)

            if let end = embedEnd(from: index, in: lines, text: text),
               !isActive(line.full.union(lines[end].full)),
               styleEmbed(Array(lines[index...end]), text: text, in: storage) {
                index = end + 1
                continue
            }
            if fence.firstMatch(in: text, range: line.content) != nil {
                // 閉じるフェンスがなければ文書の末尾までをコードとみなす
                let close = lines[(index + 1)...].firstIndex { fence.firstMatch(in: text, range: $0.content) != nil }
                let block = Array(lines[index...(close ?? lines.count - 1)])
                styleCodeBlock(block, closed: close != nil, text: text, in: storage,
                               blockActive: isActive(block.first!.full.union(block.last!.full)))
                index += block.count
                continue
            }
            if let end = tableEnd(from: index, in: lines, text: text) {
                let block = Array(lines[index..<end])
                context.tables.append(styleTable(block, text: text, in: storage, availableWidth: availableWidth,
                                                 draggedWidths: context.draggedWidths, selection: context.selection, isActive: isActive))
                index = end
                continue
            }
            if quote.firstMatch(in: text, range: line.content) != nil {
                var end = index + 1
                while end < lines.count, quote.firstMatch(in: text, range: lines[end].content) != nil { end += 1 }
                let block = Array(lines[index..<end])
                if let header = toggleHeader.firstMatch(in: text, range: block[0].content) {
                    styleToggle(block, header: header, availableWidth: availableWidth, context: &context)
                } else {
                    styleQuoteBlock(block, text: text, in: storage, blockActive: isActive(block.first!.full.union(block.last!.full)),
                                    showsIcon: context.calloutIcons, expanded: context.flippedCallouts.contains(block[0].full.location),
                                    isActive: isActive)
                }
                index = end
                continue
            }
            let above = (0..<index).reversed().lazy.map { ($0, string.substring(with: lines[$0].content)) }
            if let owner = ListLine.owner(of: string.substring(with: line.content), allowsBlank: true, above: above) {
                styleListContinuation(line.content, owner: string.substring(with: lines[owner].content),
                                      previous: lines[index - 1].content, text: text, in: storage)
                styleInline(text, line: line.content, in: storage, active: active)
                index += 1
                continue
            }
            styleBlock(text, line: line.content, in: storage, active: active)
            styleInline(text, line: line.content, in: storage, active: active)
            index += 1
        }
    }

    // MARK: - トグル

    /// `> [!toggle]- タイトル` を、枠も背景もない Notion のトグルの形にする。行頭に ▸/▾ を描き、中身は少し字下げする。
    /// 中身の行は `>` を1段外して通常の行と同じく装飾するので、段落・リスト・表・コールアウト・入れ子のトグルをそのまま見せられる。
    /// `-` のトグルは、開閉の印で開くかカーソルが中身の行に入るまでたたむ（見出し行にカーソルがあってもたたんだまま）
    private func styleToggle(_ block: [Line], header: NSTextCheckingResult, availableWidth: CGFloat, context: inout Context) {
        let text = context.text
        let string = text as NSString
        let storage = context.storage
        let first = block[0]
        let body = Array(block.dropFirst())
        let contentActive = body.contains { context.isActive($0.full) }
        let sign = header.range(at: 1)
        let folded = sign.location != NSNotFound && string.substring(with: sign) == "-"
        let collapsed = !body.isEmpty && folded != context.flippedCallouts.contains(first.full.location) && !contentActive

        // 見出し行。記号を隠し、タイトルは本文と同じ字で ▸/▾ の右に置く
        let active = context.isActive(first.full)
        let title = header.range(at: 2)
        marker(NSRange(location: first.content.location, length: title.location - first.content.location), in: storage, active: active)
        styleInline(text, line: title, in: storage, active: active)
        let style = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = ToggleBlock.indent
        style.headIndent = ToggleBlock.indent
        style.paragraphSpacing = collapsed || body.isEmpty ? 6 : 2
        storage.addAttributes([
            .paragraphStyle: style,
            .maBlock: ToggleDecoration(collapsed: collapsed || body.isEmpty && folded,
                                       placeholder: title.length == 0 && !active ? "トグル" : nil),
        ], range: first.full)

        if collapsed {
            for line in body { hideLine(line, in: storage) }
            return
        }
        // 中身の行。`>` を1段外した行として装飾してから、外した `>` を隠し、全体を字下げする
        let inner = body.map { line -> Line in
            let prefix = quote.firstMatch(in: text, range: line.content)!.range
            return Line(full: line.full, content: NSRange(location: NSMaxRange(prefix), length: NSMaxRange(line.content) - NSMaxRange(prefix)))
        }
        styleLines(inner, availableWidth: availableWidth - ToggleBlock.indent, context: &context)
        for line in inner {
            indent(line, by: ToggleBlock.indent, in: storage)
            marker(NSRange(location: line.full.location, length: line.content.location - line.full.location),
                   in: storage, active: context.isActive(line.full))
        }
    }

    /// トグルの中身の行を字下げする。行頭の位置・タブ位置・右端（先頭から測る指定のとき）をずらし、
    /// 表や枠を描くフラグメントにも字下げの幅を伝える
    private func indent(_ line: Line, by inset: CGFloat, in storage: NSTextStorage) {
        let at = line.content.length > 0 ? line.content.location : line.full.location
        let current = storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle ?? paragraphStyle
        let style = current.mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent += inset
        style.headIndent += inset
        if style.tailIndent > 0 { style.tailIndent += inset }
        if style.tabStops.isEmpty, style.defaultTabInterval > 0 {
            // 既定の間隔のタブ位置は行の左端から数えるので、字下げした位置から数える明示の位置にする
            style.tabStops = (1...16).map { NSTextTab(textAlignment: .left, location: inset + CGFloat($0) * style.defaultTabInterval) }
        } else {
            style.tabStops = style.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location + inset, options: $0.options) }
        }
        let nested = storage.attribute(.maInset, at: line.full.location, effectiveRange: nil) as? CGFloat ?? 0
        storage.addAttributes([.paragraphStyle: style, .maInset: nested + inset], range: line.full)
    }

    /// たたんだ行。文字を隠し、高さと前後の余白をなくす
    private func hideLine(_ line: Line, in storage: NSTextStorage) {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0.01
        style.maximumLineHeight = 0.01
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: style], range: line.full)
    }

    // MARK: - コードブロック

    /// ``` / ~~~ で囲んだブロックを等幅にし、全行に同じ装飾を付けて背景を1枚の角丸で描かせる。
    /// カーソルがブロックの外にあるあいだはフェンス行を隠して上下の余白にし、言語名は右上に控えめに描く
    private func styleCodeBlock(_ block: [Line], closed: Bool, text: String, in storage: NSTextStorage, blockActive: Bool) {
        let string = text as NSString
        let language = string.substring(with: block[0].content)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`~").union(.whitespaces))
        let padding = CodeBlockDecoration.padding
        for (offset, line) in block.enumerated() {
            let isFence = offset == 0 || (closed && offset == block.count - 1)
            let isLast = offset == block.count - 1
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = padding
            style.headIndent = padding
            style.tailIndent = -padding
            style.lineSpacing = 2
            var attributes: [NSAttributedString.Key: Any] = [.font: monoFont]
            if isFence && !blockActive {
                style.minimumLineHeight = CodeBlockDecoration.fenceHeight
                style.maximumLineHeight = CodeBlockDecoration.fenceHeight
                style.lineSpacing = 0
                attributes = [.font: hiddenFont, .foregroundColor: NSColor.clear]
            } else if isFence {
                attributes[.foregroundColor] = NSColor.tertiaryLabelColor
                // 見せているフェンス行が背景の端に張り付かないよう、段落の前後に余白を足す（背景はこの分も塗られる）
                if offset == 0 { style.paragraphSpacingBefore = 4 } else { style.paragraphSpacing = 4 }
            }
            // 閉じていないブロックは最後の行の下に余白がないので、段落の後ろの間隔で補う
            if isLast && !closed { style.paragraphSpacing = CodeBlockDecoration.fenceHeight }
            let showsLanguage = offset == 1 && !blockActive && !language.isEmpty && !(closed && isLast)
            attributes[.paragraphStyle] = style
            attributes[.maBlock] = CodeBlockDecoration(isFirst: offset == 0, isLast: isLast,
                                                       language: showsLanguage ? language : nil)
            storage.addAttributes(attributes, range: line.full)
        }
    }

    // MARK: - Link Embed

    /// `index` の行が ```embed なら、閉じるフェンスの行番号を返す
    private func embedEnd(from index: Int, in lines: [Line], text: String) -> Int? {
        let string = text as NSString
        func trimmedLine(_ line: Line) -> String { string.substring(with: line.content).trimmingCharacters(in: .whitespaces) }
        guard trimmedLine(lines[index]) == "```embed" else { return nil }
        return lines[(index + 1)...].firstIndex { trimmedLine($0) == "```" }
    }

    /// ```embed ブロックの文字をすべて隠し、最初の行の高さをカードの分にしてカードを描かせる。
    /// 中身が読めない（url がない）ときは false を返し、通常のコードブロックとして見せる
    private func styleEmbed(_ block: [Line], text: String, in storage: NSTextStorage) -> Bool {
        let string = text as NSString
        let body = block.dropFirst().dropLast().map { string.substring(with: $0.content) }.joined(separator: "\n")
        guard let card = EmbedCard.parse(body) else { return false }
        for (offset, line) in block.enumerated() {
            let height = offset == 0 ? EmbedCard.lineHeight : 0.01
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: style], range: line.full)
        }
        storage.addAttribute(.maBlock, value: card, range: block[0].full)
        return true
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
        _ block: [Line], text: String, in storage: NSTextStorage, availableWidth: CGFloat,
        draggedWidths: (separator: Int, widths: [CGFloat])?, selection: NSRange?, isActive: (NSRange) -> Bool
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
        // カーソルのあるセル（行の番号と列）。選択が1つのセルに収まるときだけ
        var live: (row: Int, column: Int)?
        if let selection,
           let rowIndex = rows.firstIndex(where: { $0.line.full.location <= selection.location && selection.location <= NSMaxRange($0.line.content) }),
           NSMaxRange(selection) <= NSMaxRange(rows[rowIndex].line.content) {
            let cells = rows[rowIndex].cells
            // 先頭の縦棒の前は最初のセル、末尾の縦棒の後ろは最後のセルとみなす
            func column(at location: Int) -> Int { cells.firstIndex { location <= NSMaxRange($0) } ?? cells.count - 1 }
            let start = column(at: selection.location)
            if !cells.isEmpty, start < columnCount, start == column(at: NSMaxRange(selection)) { live = (rowIndex, start) }
        }

        // 1. 文字の装飾。セルの中身だけを見せ、縦棒と前後の空白は幅ゼロにする
        var textRanges: [[NSRange]] = []
        for (rowIndex, row) in rows.enumerated() {
            let active = isActive(row.line.full)
            storage.addAttribute(.font, value: row.isHeader ? TableRowDecoration.headerFont : TableRowDecoration.bodyFont, range: row.line.content)
            let cells = row.cells.map { trimmed($0, in: string) }
            textRanges.append(cells)
            var visible = IndexSet()
            for (column, cell) in cells.enumerated() where cell.length > 0 {
                if column < columnCount { visible.insert(integersIn: cell.location..<NSMaxRange(cell)) }
                // カーソルのあるセルがある行では、ほかのセルはフラグメントが描くので、記号を隠した形で装飾する
                let isLive = live.map { $0 == (rowIndex, column) }
                styleInline(text, line: cell, in: storage, active: isLive ?? active)
                // <br> はセル内の改行として「↵」で示す
                for match in lineBreakTag.matches(in: text, range: cell) {
                    let last = NSRange(location: NSMaxRange(match.range) - 1, length: 1)
                    storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear],
                                          range: NSRange(location: match.range.location, length: match.range.length - 1))
                    if isLive == true {
                        // 編集中のセルでは「>」を表示のうえで改行に置き換え、行末に「↵」を薄く出す
                        storage.addAttributes([.foregroundColor: NSColor.clear, .maLineBreak: true,
                                               .maReplacement: Replacement("↵", color: .tertiaryLabelColor)], range: last)
                        continue
                    }
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
            row.map { $0.length > 0 ? laidOutWidth($0, in: storage) : 0 }
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
        if let draggedWidths, draggedWidths.separator == block[1].content.location, draggedWidths.widths.count == columnCount {
            widths = draggedWidths.widths
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
            var carried: CGFloat = 0
            let lineStart = row.line.content.location
            for column in 0..<min(columnCount, row.cells.count) {
                let content = textRanges[rowIndex][column]
                let width = measured[rowIndex][column]
                let left: CGFloat
                switch column < alignments.count ? alignments[column] : .left {
                case .center: left = max(0, (drawn[column] - width) / 2)
                case .right: left = max(0, drawn[column] - padding - width)
                default: left = padding
                }
                // 余白はセルの文字の直前の文字（隠した縦棒か空白）の字間に足す。前の列の右の余白もここに持ち越す。
                // 「）」「」」などの全角の閉じ約物の直後の文字では字間が効かないので、セルの最後の文字の後ろには付けない
                if content.location > lineStart { kerns[content.location - 1, default: 0] += carried + left } else { indent += carried + left }
                carried = max(0, drawn[column] - left - width)
            }
            // カーソルのない行で、<br> や列幅に収まらない文字があるセルがあれば、フラグメントが改行・折り返して描く。
            // カーソルのあるセルがある行は、ほかのセルをフラグメントが描き、そのセルだけ元の文字を列の中で折り返す
            var cellTexts: [NSAttributedString]?
            var height = TableRowDecoration.rowHeight
            let wraps = (0..<min(columnCount, row.cells.count)).contains { column in
                let content = textRanges[rowIndex][column]
                return content.length > 0 && (lineBreakTag.firstMatch(in: text, range: content) != nil
                    || measured[rowIndex][column] > drawn[column] - padding * 2)
            }
            if let live, live.row == rowIndex {
                styleLiveRow(row.line, isHeader: row.isHeader, cells: textRanges[rowIndex], column: live.column, wraps: wraps,
                             widths: drawn, alignments: alignments, layout: layout, isLast: rowIndex == rows.count - 1,
                             in: storage, text: text)
                continue
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

    /// カーソルのあるセルがある行。そのセルの文字だけを段落のインデントで列の中に置き、列の幅で折り返す
    /// （<br> は表示のうえで改行に置き換える）。ほかのセルは装飾済みの文字をフラグメントが描き、元の文字は幅ゼロで隠す。
    /// 1つの段落の文字は1列にしか流せないので、複数のセルを同時に元の文字のまま複数行にはできない
    private func styleLiveRow(
        _ line: Line, isHeader: Bool, cells: [NSRange], column live: Int, wraps: Bool, widths: [CGFloat],
        alignments: [NSTextAlignment], layout: TableLayout, isLast: Bool, in storage: NSTextStorage, text: String
    ) {
        let padding = TableRowDecoration.cellPadding
        let vertical = TableRowDecoration.verticalPadding
        let alignment = { (column: Int) in column < alignments.count ? alignments[column] : .left }
        var texts = (0..<widths.count).map { column -> NSAttributedString in
            guard column < cells.count, cells[column].length > 0 else { return NSAttributedString() }
            return cellText(cells[column], alignment: alignment(column), in: storage, text: text)
        }
        let heights = texts.enumerated().map { column, cell in
            cell.boundingRect(with: CGSize(width: max(1, widths[column] - padding * 2), height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        }
        let height = wraps ? max(TableRowDecoration.rowHeight, ceil(heights.max() ?? 0) + vertical * 2 + 4) : TableRowDecoration.rowHeight
        // 編集中のセルはフラグメントでは描かない
        texts[live] = NSAttributedString()

        let content = cells[live]
        for index in line.content.location..<NSMaxRange(line.content) where !NSLocationInRange(index, content) {
            storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: index, length: 1))
        }
        // 隠した文字に残った記号の差し替えと字間（<br> の「>」の字間など）も外す
        for hidden in [NSRange(location: line.content.location, length: max(0, content.location - line.content.location)),
                       NSRange(location: NSMaxRange(content), length: NSMaxRange(line.content) - NSMaxRange(content))] {
            storage.removeAttribute(.maReplacement, range: hidden)
            storage.removeAttribute(.kern, range: hidden)
        }

        // 行の高さと行間は、フラグメントが描く折り返した文字（lineSpacing 2）に揃える
        let font = isHeader ? TableRowDecoration.headerFont : TableRowDecoration.bodyFont
        let lineHeight = font.ascender - font.descender + font.leading
        let lines = max(1, Int(((heights[live] + 2) / (lineHeight + 2)).rounded()))
        let left = widths.prefix(live).reduce(0, +)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.alignment = alignment(live)
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineSpacing = 2
        style.firstLineHeadIndent = left + padding
        style.headIndent = left + padding
        // 隠した文字にもわずかな幅があるので、1pt の余裕を持たせる（足りないと行末の隠した文字だけが次の行に回る）
        style.tailIndent = left + widths[live] - padding + 1
        // TextKit 2 は行間を行の上に入れるので、そのままではフラグメントが描く文字より下に出る。上の余白を 1pt 減らす
        style.paragraphSpacingBefore = vertical - 1
        // 行高を固定したほかの行は、実際には指定より 3pt 低く並ぶ（ベースラインを上げた分が詰まる）。
        // カーソルが入っても行の高さが変わらないよう、同じだけ低くする
        style.paragraphSpacing = max(0, height - 3 - style.paragraphSpacingBefore - CGFloat(lines) * (lineHeight + 2))
        storage.addAttributes([
            .paragraphStyle: style,
            .baselineOffset: 0,
            .maBlock: TableRowDecoration(kind: isHeader ? .header : .body, layout: layout, isLast: isLast, cellTexts: texts,
                                         liveColumn: live),
        ], range: line.full)
    }

    /// 並べたときの文字の幅。「。」などの全角の約物は、行末では詰めて測られるが、表では後ろに隠した文字が続くので詰まらない。
    /// 後ろの1文字（幅ゼロのフォントで隠した縦棒か空白）も含めて測る
    private func laidOutWidth(_ range: NSRange, in storage: NSTextStorage) -> CGFloat {
        let string = storage.string as NSString
        var measured = range
        if NSMaxRange(range) < string.length, string.character(at: NSMaxRange(range)) != 0x0A { measured.length += 1 }
        return ceil(storage.attributedSubstring(from: measured).size().width)
    }

    /// セルの文字を <br> で区切ったときの、最も長い行の幅
    private func widestLine(_ range: NSRange, in storage: NSTextStorage, text: String) -> CGFloat {
        var widest: CGFloat = 0
        var start = range.location
        for match in lineBreakTag.matches(in: text, range: range) + [nil] {
            let end = match?.range.location ?? NSMaxRange(range)
            if end > start {
                widest = max(widest, laidOutWidth(NSRange(location: start, length: end - start), in: storage))
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
        _ block: [Line], text: String, in storage: NSTextStorage, blockActive: Bool, showsIcon: Bool, expanded: Bool,
        isActive: (NSRange) -> Bool
    ) {
        let header = calloutHeader.firstMatch(in: text, range: block[0].content)
        let string = text as NSString
        let callout = header.map { match -> CalloutStyle in
            let type = string.substring(with: match.range(at: 1)).lowercased()
            return CalloutStyle(type: type)
        }
        // [!note]- は、カーソルがコールアウトの外にあり、開閉の印で開いてもいないあいだ本文をたたむ
        let folded = header.map { $0.range(at: 2).location != NSNotFound && string.substring(with: $0.range(at: 2)) == "-" } ?? false
        let collapsed = folded && !blockActive && !expanded

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
            if isLast && callout != nil { style.paragraphSpacing = 18 }

            if let header, isFirst, let callout {
                let title = header.range(at: 3)
                style.firstLineHeadIndent = showsIcon ? 14 + 24 : 14
                marker(NSRange(location: line.content.location, length: title.location - line.content.location), in: storage, active: active)
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                    .foregroundColor: callout.color,
                ], range: title)
                styleCalloutTitleCheckbox(title, text: text, color: callout.color, in: storage, active: active)
                styleInline(text, line: title, in: storage, active: active)
                let fallback = title.length == 0 && !active ? callout.defaultTitle : nil
                storage.addAttributes([
                    .paragraphStyle: style,
                    .maBlock: BoxDecoration(
                        color: callout.color, icon: showsIcon ? callout.icon : nil, fallbackTitle: fallback,
                        foldable: folded, collapsed: collapsed, isFirst: true, isLast: isLast
                    ),
                ], range: line.full)
                continue
            }
            if collapsed {
                style.minimumLineHeight = 0.01
                style.maximumLineHeight = 0.01
                style.lineSpacing = 0
                // 最後の行の下の余白（枠の内側の余白）も消す。残すと、たたんだ枠の下が空く
                style.paragraphSpacing = 0
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

    /// タイトルの先頭の `[ ]` `[-]` `[x]` をチェックボックスにする。完了はタイトルを薄くして打ち消し線を引く。
    /// カーソル行はチェックリストと同じく記号をそのまま見せる
    private func styleCalloutTitleCheckbox(_ title: NSRange, text: String, color: NSColor, in storage: NSTextStorage, active: Bool) {
        guard let match = calloutTitleCheckbox.firstMatch(in: text, range: title),
              let state = CheckboxState(mark: Character((text as NSString).substring(with: match.range(at: 1))))
        else { return }
        let brackets = match.range
        if active {
            marker(brackets, in: storage, active: true)
        } else {
            hideCheckboxBrackets(brackets, state: state, in: storage)
        }
        if state == .done {
            let rest = NSRange(location: NSMaxRange(brackets), length: NSMaxRange(title) - NSMaxRange(brackets))
            storage.addAttributes([
                .foregroundColor: color.withAlphaComponent(0.5),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ], range: rest)
        }
    }

    /// `[ ]` を透明にして `.maCheckbox` を付け、フラグメントにチェックボックスを描かせる。
    /// 本文のフォントのままだと `[` `]` にヒラギノが割り当てられ（日本語環境の約物の扱い）、その行だけ約 6pt 高くなる。
    /// 透明で見えない文字なので置き換えの起きないフォントにし、幅はチェックボックスに合わせる
    private func hideCheckboxBrackets(_ brackets: NSRange, state: CheckboxState, in storage: NSTextStorage) {
        let bracketWidth = "[ ]".size(withAttributes: [.font: checkboxFont]).width
        storage.addAttributes([.foregroundColor: NSColor.clear, .maCheckbox: state.rawValue, .font: checkboxFont], range: brackets)
        storage.addAttribute(.kern, value: 14 - bracketWidth, range: NSRange(location: NSMaxRange(brackets) - 1, length: 1))
    }

    /// 項目の続きの行（Shift+Enter で項目の中で改行した行）。行頭の空白を透明にし、本文を項目の本文の左端に揃える。
    /// 空白を箇条書きの1段の幅で数えると、1段深い子の項目のように見えるので、空白の文字数によらず項目の本文の位置へ送る。
    /// 項目との間は折り返した行と同じ行間にする
    private func styleListContinuation(_ line: NSRange, owner: String, previous: NSRange, text: String, in storage: NSTextStorage) {
        let target = listBodyOffset(of: owner)
        let style = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
        style.paragraphSpacing = 2
        style.tabStops = []
        style.defaultTabInterval = listIndentStep
        style.headIndent = target
        storage.addAttribute(.paragraphStyle, value: style, range: line)
        if previous.length > 0,
           let above = storage.attribute(.paragraphStyle, at: previous.location, effectiveRange: nil) as? NSParagraphStyle {
            let tight = above.mutableCopy() as! NSMutableParagraphStyle
            tight.paragraphSpacing = 0
            storage.addAttribute(.paragraphStyle, value: tight, range: previous)
        }
        // 空白を透明の細いフォントにし、最後の空白の字間で本文の位置まで送る。タブは1段ごとのタブ位置へ進む
        let string = text as NSString
        let whitespace = (ListLine.leadingWhitespace(string.substring(with: line)) as NSString).length
        guard whitespace > 0 else { return }
        // 完了した項目の続きは、項目の行と同じく薄くして打ち消し線を引く
        if let checkbox = ListLine.marker(of: owner)?.checkbox, !checkbox.hasPrefix("[ ]") {
            storage.addAttributes([
                .foregroundColor: NSColor.secondaryLabelColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ], range: NSRange(location: line.location + whitespace, length: line.length - whitespace))
        }
        storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear],
                              range: NSRange(location: line.location, length: whitespace))
        var x: CGFloat = 0
        for offset in 0..<(whitespace - 1) where string.character(at: line.location + offset) == 0x09 {
            x = (floor(x / listIndentStep) + 1) * listIndentStep
        }
        let lastWhitespace = NSRange(location: line.location + whitespace - 1, length: 1)
        var lastAdvance: CGFloat = 0
        if whitespace == line.length {
            // 空白だけの入力中の行も本文と同じ高さにする。全文字が hiddenFont だと、
            // TextKit がカーソルも 0.01pt の高さにしてしまう。文字自体は透明のままにする。
            storage.addAttribute(.font, value: bodyFont, range: lastWhitespace)
            if string.character(at: lastWhitespace.location) == 0x20 {
                lastAdvance = (" " as NSString).size(withAttributes: [.font: bodyFont]).width
            }
        }
        storage.addAttribute(.kern, value: max(0, target - x) - lastAdvance, range: lastWhitespace)
    }

    /// 項目の行の本文の左端の位置。カーソルが外にあるときの表示（記号を中黒やチェックボックスにした表示）で測る
    private func listBodyOffset(of item: String) -> CGFloat {
        guard let marker = ListLine.marker(of: item) else { return 0 }
        func width(_ string: String, _ font: NSFont) -> CGFloat {
            (string as NSString).size(withAttributes: [.font: font]).width
        }
        // 行頭の空白は styleBlock と同じく、空白2つとタブ1つを1段の幅で数える
        var x: CGFloat = 0
        for character in marker.indent {
            x = character == "\t" ? (floor(x / listIndentStep) + 1) * listIndentStep : x + listIndentStep / 2
        }
        if let checkbox = marker.checkbox {
            // 記号は隠れ、`[ ]` は字間でチェックボックスの幅（14pt）に揃える（hideCheckboxBrackets と同じ計算。`[x]` は少し広くなる）
            let brackets = width(String(checkbox.prefix(3)), checkboxFont) + 14 - width("[ ]", checkboxFont)
            x += width(marker.spacing, bodyFont) + brackets + width(String(checkbox.dropFirst(3)), bodyFont)
        } else {
            x += width(marker.bullet + marker.spacing, bodyFont)
        }
        return x
    }

    private func styleBlock(_ text: String, line: NSRange, in storage: NSTextStorage, active: Bool) {
        if let match = heading.firstMatch(in: text, range: line) {
            let level = match.range(at: 1).length
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: headingSizes[level], weight: .bold), range: line)
            storage.addAttribute(.foregroundColor, value: NSColor.maStrongText, range: line)
            // h1・h2 は上下に余白を空け、前後の本文と区切る。文書の先頭の見出しには上の余白を付けない
            if level <= 2 {
                let style = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
                style.paragraphSpacing = level == 1 ? 14 : 10
                style.paragraphSpacingBefore = line.location == 0 ? 0 : (level == 1 ? 20 : 16)
                storage.addAttribute(.paragraphStyle, value: style, range: line)
            }
            marker(match.range, in: storage, active: active)
        } else if let match = quote.firstMatch(in: text, range: line) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line)
            marker(match.range, in: storage, active: active)
        } else if rule.firstMatch(in: text, range: line) != nil {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: line)
        } else if let match = listMarker.firstMatch(in: text, range: line) {
            // 箇条書きとタスクは項目どうしの間をわずかに空ける（折り返した行の行間より 2pt 広いだけにして詰める）
            let style = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = 2
            // 行頭の空白2つとタブ1つを同じ1段の幅にする。タブは1段ごとのタブ位置へ進み、空白は字間で半段に広げる。
            // 字間は連続する空白の先頭の1文字にまとめて付ける（空白ごとに付けると、足される幅が文字数ぶんにならない）
            style.tabStops = []
            style.defaultTabInterval = listIndentStep
            storage.addAttribute(.paragraphStyle, value: style, range: line)
            let string = text as NSString
            var index = line.location
            while index < NSMaxRange(line), string.character(at: index) == 0x09 || string.character(at: index) == 0x20 {
                let start = index
                while index < NSMaxRange(line), string.character(at: index) == 0x20 { index += 1 }
                if index > start {
                    storage.addAttribute(.kern, value: CGFloat(index - start) * spaceKern, range: NSRange(location: start, length: 1))
                } else {
                    index += 1
                }
            }
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
            // タスクは箇条書きの記号を隠し、`[ ]` を透明にしてその位置にチェックボックスを描く。
            // カーソル行は `- [ ]` をそのまま文字で見せ、チェックボックスは描かない（クリックの当たり判定も `.maCheckbox` から求めるので無効になる）
            marker(match.range(at: 1), in: storage, active: active)
            let brackets = NSRange(location: checkbox.location, length: 3)
            let checked = (text as NSString).character(at: brackets.location + 1) != 0x20
            if active {
                marker(brackets, in: storage, active: true)
            } else {
                hideCheckboxBrackets(brackets, state: checked ? .done : .open, in: storage)
            }
            if checked {
                let rest = NSRange(location: NSMaxRange(checkbox), length: NSMaxRange(line) - NSMaxRange(checkbox))
                storage.addAttributes([
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ], range: rest)
            }
        } else if line.length > 0 {
            // 通常の段落は下に余白を空ける（空行は元から間隔になる）
            let style = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = 6
            storage.addAttribute(.paragraphStyle, value: style, range: line)
        }
    }

    private func styleInline(_ text: String, line: NSRange, in storage: NSTextStorage, active: Bool) {
        // コードの中は他の記法として解釈しない。コードを記号でも空白でもない文字で塗りつぶした行を作り、他の記法はそこで探す。
        // コードと重なる一致を捨てるだけだと、**`code`** のようにコードを丸ごと囲む記法まで捨ててしまう
        let string = text as NSString
        let masked = NSMutableString(string: string.substring(with: line))
        for match in inlineCode.matches(in: text, range: line) {
            storage.addAttributes([.font: monoFont, .backgroundColor: NSColor.quaternarySystemFill], range: match.range)
            wrapMarkers(match.range, length: 1, in: storage, active: active)
            masked.replaceCharacters(
                in: NSRange(location: match.range.location - line.location, length: match.range.length),
                with: String(repeating: "\u{FFFC}", count: match.range.length)
            )
        }
        // AI へのコメントは、選んだ文字をハイライトし、コメントは隠してホバーでポップオーバーに出す。コメントの中は他の記法として読まない。
        // 選んだ文字の `==…==` に通常のハイライトの黄色が重ならないよう、ハイライトは AI へのコメント全体を塗りつぶした行で探す
        let highlightMasked = NSMutableString(string: masked)
        for match in aiComment.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)) {
            let whole = match.range.offset(by: line.location)
            let body = match.range(at: 1).offset(by: line.location)
            let comment = match.range(at: 2).offset(by: line.location)
            let note = string.substring(with: match.range(at: 3).offset(by: line.location))
            storage.addAttribute(.backgroundColor, value: NSColor.maAIComment, range: body)
            if !active { storage.addAttribute(.maAIComment, value: note, range: body) }
            marker(NSRange(location: whole.location, length: 2), in: storage, active: active)
            marker(NSRange(location: NSMaxRange(body), length: 2), in: storage, active: active)
            marker(comment, in: storage, active: active)
            masked.replaceCharacters(in: match.range(at: 2), with: String(repeating: "\u{FFFC}", count: comment.length))
            highlightMasked.replaceCharacters(in: match.range, with: String(repeating: "\u{FFFC}", count: whole.length))
        }
        let maskedText = masked as String
        func matches(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
            regex.matches(in: maskedText, range: NSRange(location: 0, length: masked.length))
                .map { $0.adjustingRanges(offset: line.location) }
        }

        for match in matches(bold) {
            addTrait(.boldFontMask, range: match.range, in: storage)
            lightenBoldText(match.range, in: storage)
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
        for match in highlight.matches(in: highlightMasked as String, range: NSRange(location: 0, length: highlightMasked.length)) {
            let range = match.range.offset(by: line.location)
            storage.addAttribute(.backgroundColor, value: NSColor.maHighlight, range: range)
            wrapMarkers(range, length: 2, in: storage, active: active)
        }
        for match in matches(wikiLink) {
            let name = string.substring(with: match.range(at: 1))
            let target = name.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            storage.addAttributes([
                .foregroundColor: NSColor.maLink,
                .maWikiLink: target.trimmingCharacters(in: .whitespaces),
            ], range: match.range)
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
            storage.addAttribute(.foregroundColor, value: NSColor.maLink, range: label)
            storage.addAttribute(.maURL, value: string.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces), range: match.range)
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

    /// 太字は線が太いぶん濃く見えるので、本文の色のままの部分だけ少し明るくする（リンクなどの色は残す）
    private func lightenBoldText(_ range: NSRange, in storage: NSTextStorage) {
        storage.enumerateAttribute(.foregroundColor, in: range) { value, subrange, _ in
            if value as? NSColor == .maText {
                storage.addAttribute(.foregroundColor, value: NSColor.maStrongText, range: subrange)
            }
        }
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

private extension NSRange {
    func offset(by delta: Int) -> NSRange { NSRange(location: location + delta, length: length) }
}
