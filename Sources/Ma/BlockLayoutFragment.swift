import AppKit

extension NSAttributedString.Key {
    /// 段落の先頭に付け、レイアウトフラグメントに描かせる装飾を渡す
    static let maBlock = NSAttributedString.Key("ma.block")
    /// タスクの `[ ]` に付ける。値はチェック済みかどうか
    static let maCheckbox = NSAttributedString.Key("ma.checkbox")
    /// 文字を透明にして、代わりに描く記号（箇条書きの中黒や <br> の ↵）
    static let maReplacement = NSAttributedString.Key("ma.replacement")
    /// `[[ノート名]]` 全体に付ける。値はリンク先のノート名（`#見出し` や `|表示名` を含まない）
    static let maWikiLink = NSAttributedString.Key("ma.wikiLink")
    /// `[表示名](URL)` 全体に付ける。値は URL の文字列
    static let maURL = NSAttributedString.Key("ma.url")
}

/// 文字の代わりに、その文字の位置の中央へ描く記号
final class Replacement: NSObject, @unchecked Sendable {
    let symbol: String
    let color: NSColor

    init(_ symbol: String, color: NSColor) {
        self.symbol = symbol
        self.color = color
    }

    // 再装飾のたびに作り直すので、中身で比べる（変わっていない段落のレイアウトを捨てないため）
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Replacement else { return false }
        return symbol == other.symbol && color == other.color
    }

    override var hash: Int { symbol.hashValue }
}

/// 引用とコールアウトの枠
final class BoxDecoration: NSObject, @unchecked Sendable {
    let color: NSColor
    let icon: String?
    /// タイトルが空で記号を隠しているときに、代わりに描く種類名
    let fallbackTitle: String?
    let foldable: Bool
    let collapsed: Bool
    let isFirst: Bool
    let isLast: Bool
    /// 引用は背景を塗らず、左に線だけを引く
    let isQuote: Bool

    init(color: NSColor, icon: String?, fallbackTitle: String?, foldable: Bool, collapsed: Bool,
         isFirst: Bool, isLast: Bool, isQuote: Bool = false) {
        self.color = color
        self.icon = icon
        self.fallbackTitle = fallbackTitle
        self.foldable = foldable
        self.collapsed = collapsed
        self.isFirst = isFirst
        self.isLast = isLast
        self.isQuote = isQuote
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BoxDecoration else { return false }
        return color == other.color && icon == other.icon && fallbackTitle == other.fallbackTitle && foldable == other.foldable
            && collapsed == other.collapsed && isFirst == other.isFirst && isLast == other.isLast && isQuote == other.isQuote
    }

    override var hash: Int { icon.hashValue ^ isFirst.hashValue ^ isLast.hashValue }

    static func quote(isFirst: Bool, isLast: Bool) -> BoxDecoration {
        BoxDecoration(color: .tertiaryLabelColor, icon: nil, fallbackTitle: nil, foldable: false, collapsed: false,
                      isFirst: isFirst, isLast: isLast, isQuote: true)
    }
}

/// Obsidian のコールアウトの種類ごとの色とアイコン
struct CalloutStyle {
    let color: NSColor
    let icon: String
    let defaultTitle: String

    init(type: String) {
        defaultTitle = type.prefix(1).uppercased() + type.dropFirst()
        switch type {
        case "abstract", "summary", "tldr": (color, icon) = (.systemTeal, "doc.text")
        case "info": (color, icon) = (.systemBlue, "info.circle")
        case "todo": (color, icon) = (.systemBlue, "checkmark.circle")
        case "tip", "hint", "important": (color, icon) = (.systemTeal, "flame")
        case "success", "check", "done": (color, icon) = (.systemGreen, "checkmark")
        case "question", "help", "faq": (color, icon) = (.systemOrange, "questionmark.circle")
        case "warning", "caution", "attention": (color, icon) = (.systemOrange, "exclamationmark.triangle")
        case "failure", "fail", "missing": (color, icon) = (.systemRed, "xmark")
        case "danger", "error": (color, icon) = (.systemRed, "bolt")
        case "bug": (color, icon) = (.systemRed, "ladybug")
        case "example": (color, icon) = (.systemPurple, "list.bullet")
        case "quote", "cite": (color, icon) = (.systemGray, "quote.opening")
        default: (color, icon) = (.systemBlue, "pencil")
        }
    }
}

/// 表全体で共有する列の情報。列幅のドラッグ中は `columnWidths` を書き換えて再描画する
final class TableLayout: NSObject, @unchecked Sendable {
    /// 区切り行のセル1文字（`-` と `:`）あたりの幅。桁揃えされた表では文字数が半角換算の文字数に近くなる
    static let dashWidth: CGFloat = 8
    static let minimumWidth: CGFloat = 40

    var columnWidths: [CGFloat]
    let alignments: [NSTextAlignment]
    /// 区切り行（|---|）の範囲。ドラッグを終えたらここを書き換えて幅を保存する
    let separatorRange: NSRange
    /// 見出し行と本文の各行の、セルの範囲（縦棒の間）。区切り行は含まない
    let rows: [[NSRange]]
    let tableRange: NSRange

    init(columnWidths: [CGFloat], alignments: [NSTextAlignment], separatorRange: NSRange, rows: [[NSRange]],
         tableRange: NSRange) {
        self.columnWidths = columnWidths
        self.alignments = alignments
        self.separatorRange = separatorRange
        self.rows = rows
        self.tableRange = tableRange
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableLayout else { return false }
        return columnWidths == other.columnWidths && alignments == other.alignments && separatorRange == other.separatorRange
            && rows == other.rows && tableRange == other.tableRange
    }

    override var hash: Int { separatorRange.location }

    /// 最終行の末尾（改行の手前）。行を追加するときはここに挿入する
    var endOfLastRow: Int {
        var end = NSMaxRange(tableRange)
        if let last = rows.last?.last { end = max(NSMaxRange(last), end - 1) }
        return end
    }

    /// `location` を含むセルの位置
    func cell(containing location: Int) -> (row: Int, column: Int)? {
        for (row, cells) in rows.enumerated() {
            for (column, cell) in cells.enumerated() where cell.location <= location && location <= NSMaxRange(cell) {
                return (row, column)
            }
        }
        return nil
    }

    /// 区切り行に保存できる幅（1文字 8pt 刻み）に丸める。ドラッグ中から丸めておくと、離したときに幅が跳ねない
    static func snapped(_ width: CGFloat) -> CGFloat {
        let padding = TableRowDecoration.cellPadding * 2
        let length = max(3, ((width - padding) / dashWidth).rounded())
        return max(minimumWidth, length * dashWidth + padding)
    }

    /// 列幅の合計が本文の幅を超えるときは、比率を保って縮める
    func scaledWidths(available: CGFloat) -> (widths: [CGFloat], scale: CGFloat) {
        let scale = min(1, available / max(columnWidths.reduce(0, +), 1))
        return (columnWidths.map { floor($0 * scale) }, scale)
    }

    /// 区切り行のセルに付く `:` の数
    private func colonCount(_ column: Int) -> Int {
        switch column < alignments.count ? alignments[column] : .left {
        case .center: return 2
        case .right: return 1
        default: return 0
        }
    }

    /// 区切り行に保存できる最も狭い幅（`-` 3 本と揃えの `:`）
    func minimumWidth(of column: Int) -> CGFloat {
        max(Self.minimumWidth, CGFloat(3 + colonCount(column)) * Self.dashWidth + TableRowDecoration.cellPadding * 2)
    }

    /// 現在の列幅を `-` の数に直した区切り行
    func separatorLine() -> String {
        let colons = columnWidths.indices.map(colonCount)
        var dashes = columnWidths.enumerated().map { column, width -> Int in
            // 自動幅の列は中身に合わせた半端な幅なので、切り上げて中身が折り返さないようにする
            // （ドラッグした列は 8pt 刻みに丸めてあるので変わらない）
            let length = Int(((width - TableRowDecoration.cellPadding * 2) / Self.dashWidth - 0.01).rounded(.up))
            return max(3, length - colons[column])
        }
        // どの列も `-` が 3 本以下だと自動幅として読まれるので、いちばん広い列を 4 本にする
        if !dashes.contains(where: { $0 > 3 }), let widest = columnWidths.indices.max(by: { columnWidths[$0] < columnWidths[$1] }) {
            dashes[widest] = 4
        }
        let cells = dashes.enumerated().map { column, count -> String in
            let body = String(repeating: "-", count: count)
            switch colons[column] {
            case 2: return ":" + body + ":"
            case 1: return body + ":"
            default: return body
            }
        }
        return "| " + cells.joined(separator: " | ") + " |"
    }
}

/// 表の1行
final class TableRowDecoration: NSObject, @unchecked Sendable {
    enum Kind { case header, separator, body }

    nonisolated(unsafe) static let bodyFont = NSFont.systemFont(ofSize: 14)
    nonisolated(unsafe) static let headerFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let cellPadding: CGFloat = 10
    static let rowHeight: CGFloat = 30

    /// 行の上下の余白。1行の行では文字が縦中央に来る
    static var verticalPadding: CGFloat { (rowHeight - (bodyFont.ascender - bodyFont.descender)) / 2 }

    let kind: Kind
    let layout: TableLayout
    let isLast: Bool
    /// セル内の改行や折り返しがある行で、フラグメントが描くセルの文字。nil なら元の文字をそのまま見せている
    let cellTexts: [NSAttributedString]?

    init(kind: Kind, layout: TableLayout, isLast: Bool, cellTexts: [NSAttributedString]? = nil) {
        self.kind = kind
        self.layout = layout
        self.cellTexts = cellTexts
        self.isLast = isLast
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableRowDecoration else { return false }
        return kind == other.kind && isLast == other.isLast && layout == other.layout && cellTexts == other.cellTexts
    }

    override var hash: Int { layout.hash }
}

/// 段落に付いた装飾を、テキストの下（背景・罫線）と上（アイコン・セル）に描く
final class BlockLayoutFragment: NSTextLayoutFragment {
    var decoration: NSObject?

    private var padding: CGFloat { textLayoutManager?.textContainer?.lineFragmentPadding ?? 5 }
    private var availableWidth: CGFloat {
        (textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width) - padding * 2
    }

    /// フラグメントの原点はインデント後の位置にあるので、本文の左端（行頭の余白の内側）までの距離を求める
    private func textLeft(from point: CGPoint) -> CGFloat {
        point.x - layoutFragmentFrame.minX + padding
    }

    /// 最初の行で、文字が占める範囲の縦中央。最小行高で広がった分は文字の上に入る
    private func firstLineTextCenter(from point: CGPoint) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 15)
        let bottom = textLineFragments.first?.typographicBounds.maxY ?? layoutFragmentFrame.height
        return point.y + bottom - (font.ascender - font.descender) / 2
    }

    /// 装飾を描く高さ。ファイル末尾の空行は直前の段落のフラグメントに含まれるので、その分を除く
    var decoratedHeight: CGFloat {
        if textLineFragments.count > 1, let extra = textLineFragments.last, extra.characterRange.length == 0 {
            return extra.typographicBounds.minY
        }
        return layoutFragmentFrame.height
    }

    /// Link Embed のカードの枠（横はテキストコンテナ、縦はフラグメントの上端からの座標）
    func embedCardRect() -> CGRect {
        EmbedCard.cardRect(left: padding, width: min(availableWidth, 640))
    }

    /// 表の各列の右端の x 座標（テキストコンテナの座標系）と、描画時の縮小率
    func columnEdges() -> (edges: [CGFloat], scale: CGFloat)? {
        guard let row = decoration as? TableRowDecoration else { return nil }
        let (widths, scale) = row.layout.scaledWidths(available: availableWidth)
        var x = padding
        return (widths.map { x += $0; return x }, scale)
    }

    override var renderingSurfaceBounds: CGRect {
        guard decoration != nil else { return super.renderingSurfaceBounds }
        let full = CGRect(x: -layoutFragmentFrame.minX, y: 0,
                          width: padding * 2 + availableWidth, height: layoutFragmentFrame.height)
        return super.renderingSurfaceBounds.union(full)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        switch decoration {
        case let box as BoxDecoration:
            drawBox(box, at: point)
            super.draw(at: point, in: context)
            drawBoxHeader(box, at: point)
            drawCheckboxes(at: point)
        case let card as EmbedCard:
            // 元の文字は透明なので、カードだけを描く
            let rect = embedCardRect().offsetBy(dx: point.x - layoutFragmentFrame.minX, dy: point.y)
            MainActor.assumeIsolated { card.draw(in: rect) }
        case let row as TableRowDecoration:
            // 罫線と背景を先に描き、セルの文字（元の Markdown の文字）はその上に通常どおり描く
            drawTableRow(row, at: point)
            super.draw(at: point, in: context)
            drawCheckboxes(at: point)
        default:
            super.draw(at: point, in: context)
            drawCheckboxes(at: point)
        }
    }

    // MARK: - 記号の差し替えとチェックボックス

    private func drawReplacements(at point: CGPoint) {
        for line in textLineFragments {
            line.attributedString.enumerateAttribute(.maReplacement, in: line.characterRange) { value, range, _ in
                guard let replacement = value as? Replacement else { return }
                let font = line.attributedString.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                    ?? NSFont.systemFont(ofSize: 15)
                let symbol = NSAttributedString(string: replacement.symbol, attributes: [
                    .font: font, .foregroundColor: replacement.color,
                ])
                let start = line.locationForCharacter(at: range.location).x
                let end = line.locationForCharacter(at: NSMaxRange(range)).x
                let bounds = line.typographicBounds
                let baselineOffset = line.attributedString.attribute(.baselineOffset, at: range.location, effectiveRange: nil) as? CGFloat ?? 0
                // ベースラインを元の文字に揃え、横は元の文字の中央に置く
                let baseline = point.y + bounds.minY + line.glyphOrigin.y - baselineOffset
                symbol.draw(at: CGPoint(x: point.x + bounds.minX + (start + end - symbol.size().width) / 2,
                                        y: baseline - font.ascender))
            }
        }
    }

    /// 段落内のチェックボックスの位置（フラグメント内の座標）と、段落内の文字範囲
    func checkboxes() -> [(rect: CGRect, range: NSRange, checked: Bool)] {
        var result: [(CGRect, NSRange, Bool)] = []
        for line in textLineFragments {
            line.attributedString.enumerateAttribute(.maCheckbox, in: line.characterRange) { value, range, _ in
                guard let checked = value as? Bool else { return }
                let start = line.locationForCharacter(at: range.location).x
                let end = line.locationForCharacter(at: NSMaxRange(range)).x
                let bounds = line.typographicBounds
                // 文字の縦中央はベースラインから大文字の高さの半分だけ上
                let centerY = bounds.minY + line.glyphOrigin.y - NSFont.systemFont(ofSize: 15).capHeight / 2
                let size: CGFloat = 14
                let rect = CGRect(x: bounds.minX + (start + end - size) / 2, y: centerY - size / 2, width: size, height: size)
                result.append((rect, range, checked))
            }
        }
        return result
    }

    private func drawCheckboxes(at point: CGPoint) {
        drawReplacements(at: point)
        for (rect, _, checked) in checkboxes() {
            let box = rect.offsetBy(dx: point.x, dy: point.y)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
            if checked {
                NSColor.controlAccentColor.setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: CGPoint(x: box.minX + 3.5, y: box.midY))
                check.line(to: CGPoint(x: box.minX + 6, y: box.maxY - 3.5))
                check.line(to: CGPoint(x: box.maxX - 3, y: box.minY + 3.5))
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                path.lineWidth = 1.2
                NSColor.secondaryLabelColor.setStroke()
                path.stroke()
            }
        }
    }

    private func drawBox(_ box: BoxDecoration, at point: CGPoint) {
        let rect = CGRect(x: textLeft(from: point), y: point.y, width: availableWidth, height: decoratedHeight)
        if box.isQuote {
            box.color.setFill()
            rect.divided(atDistance: 3, from: .minXEdge).slice.fill()
            return
        }
        // 先頭と末尾の段落だけ角を丸める。途中の段落は上下に伸ばした角丸を切り取って四角にする
        let radius: CGFloat = 6
        var shape = rect
        if !box.isFirst { shape.origin.y -= radius; shape.size.height += radius }
        if !box.isLast { shape.size.height += radius }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        box.color.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBoxHeader(_ box: BoxDecoration, at point: CGPoint) {
        guard box.isFirst, let icon = box.icon else { return }
        let center = firstLineTextCenter(from: point)
        let left = textLeft(from: point) + 14
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.init(paletteColors: [box.color]))
        if let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let size = image.size
            image.draw(
                in: CGRect(x: left + (16 - size.width) / 2, y: center - size.height / 2,
                           width: size.width, height: size.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
            )
        }
        if let title = box.fallbackTitle {
            let string = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: box.color,
            ])
            string.draw(at: CGPoint(x: left + 24, y: center - string.size().height / 2))
        }
        if box.foldable {
            let chevron = NSAttributedString(string: box.collapsed ? "›" : "⌄", attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: box.color,
            ])
            let size = chevron.size()
            chevron.draw(at: CGPoint(x: textLeft(from: point) + availableWidth - 14 - size.width,
                                     y: center - size.height / 2))
        }
    }

    private func drawTableRow(_ row: TableRowDecoration, at point: CGPoint) {
        guard row.kind != .separator else { return }
        let widths = row.layout.scaledWidths(available: availableWidth).widths
        let height = decoratedHeight
        let left = textLeft(from: point)
        let rect = CGRect(x: left, y: point.y, width: widths.reduce(0, +), height: height)

        if row.kind == .header {
            NSColor.quaternarySystemFill.setFill()
            rect.fill()
        }

        let grid = NSBezierPath()
        grid.lineWidth = 1
        if row.kind == .header {
            grid.move(to: CGPoint(x: rect.minX, y: rect.minY + 0.5))
            grid.line(to: CGPoint(x: rect.maxX, y: rect.minY + 0.5))
        }
        grid.move(to: CGPoint(x: rect.minX, y: rect.maxY - 0.5))
        grid.line(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5))
        var edges = [left + 0.5]
        for width in widths { edges.append(edges.last! + width) }
        edges = edges.enumerated().map { $0.offset == 0 ? $0.element : $0.element - 1 }
        for edge in edges {
            grid.move(to: CGPoint(x: edge, y: rect.minY))
            grid.line(to: CGPoint(x: edge, y: rect.maxY))
        }
        NSColor.separatorColor.setStroke()
        grid.stroke()

        guard let texts = row.cellTexts else { return }
        let padding = TableRowDecoration.cellPadding
        let vertical = TableRowDecoration.verticalPadding
        var x = left
        for (column, width) in widths.enumerated() {
            defer { x += width }
            guard column < texts.count else { continue }
            texts[column].draw(
                // 高さは余裕を持たせる。収まりきらない最後の行は描かれないため
                with: CGRect(x: x + padding, y: point.y + vertical, width: max(1, width - padding * 2),
                             height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        }
    }
}

/// 段落ごとに BlockLayoutFragment を作り、先頭文字に付いた装飾を渡す
final class BlockLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = BlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            fragment.decoration = paragraph.attributedString.attribute(.maBlock, at: 0, effectiveRange: nil) as? NSObject
        }
        return fragment
    }
}
