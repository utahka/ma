import AppKit

extension NSAttributedString.Key {
    /// 段落の先頭に付け、レイアウトフラグメントに描かせる装飾を渡す
    static let maBlock = NSAttributedString.Key("ma.block")
    /// タスクやコールアウトのタイトルの `[ ]` に付ける。値は `CheckboxState` の rawValue
    static let maCheckbox = NSAttributedString.Key("ma.checkbox")
    /// 文字を透明にして、代わりに描く記号（箇条書きの中黒や <br> の ↵）
    static let maReplacement = NSAttributedString.Key("ma.replacement")
    /// `[[ノート名]]` 全体に付ける。値はリンク先のノート名（`#見出し` や `|表示名` を含まない）
    static let maWikiLink = NSAttributedString.Key("ma.wikiLink")
    /// `[表示名](URL)` 全体に付ける。値は URL の文字列
    static let maURL = NSAttributedString.Key("ma.url")
    /// AI へのコメントを付けた文字に付ける。値はコメント本文。カーソル行（記号が見えている状態）では付けない
    static let maAIComment = NSAttributedString.Key("ma.aiComment")
    /// 表の編集中のセルで、<br> の「>」に付ける。表示のうえだけ行区切り（U+2028）に置き換えてセルの中で改行する
    static let maLineBreak = NSAttributedString.Key("ma.lineBreak")
    /// トグルの中身の段落に付ける。値は字下げの幅（CGFloat）。フラグメントは表や枠をこの分だけ右から描く
    static let maInset = NSAttributedString.Key("ma.inset")
}

/// チェックボックスの状態。rawValue は `[ ]` の中の文字
enum CheckboxState: String {
    /// `[ ]` 未着手
    case open = " "
    /// `[-]` 進行中・保留（コールアウトのタイトルだけ）
    case partial = "-"
    /// `[x]` 完了
    case done = "x"

    init?(mark: Character) {
        switch mark {
        case " ": self = .open
        case "-": self = .partial
        case "x", "X": self = .done
        default: return nil
        }
    }
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

/// トグル（`> [!toggle]`）の見出し行。枠や背景は描かず、行頭に ▸/▾ を描く
final class ToggleDecoration: NSObject, @unchecked Sendable {
    let collapsed: Bool
    /// タイトルが空で記号を隠しているときに、代わりに薄く描く文字
    let placeholder: String?

    init(collapsed: Bool, placeholder: String?) {
        self.collapsed = collapsed
        self.placeholder = placeholder
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ToggleDecoration else { return false }
        return collapsed == other.collapsed && placeholder == other.placeholder
    }

    override var hash: Int { collapsed.hashValue ^ placeholder.hashValue }
}

/// ``` で囲んだコードブロックの1行。ブロックの全行に付け、背景を1枚の角丸としてつなげて描く
final class CodeBlockDecoration: NSObject, @unchecked Sendable {
    /// 背景の内側の左右の余白
    static let padding: CGFloat = 16
    /// カーソルがブロックの外にあるとき、隠したフェンス行の高さ（背景の内側の上下の余白になる）
    static let fenceHeight: CGFloat = 10
    nonisolated(unsafe) static let languageFont = NSFont.systemFont(ofSize: 11)

    let isFirst: Bool
    let isLast: Bool
    /// 右上に控えめに描く言語名。フェンス行を見せているときは nil
    let language: String?

    init(isFirst: Bool, isLast: Bool, language: String?) {
        self.isFirst = isFirst
        self.isLast = isLast
        self.language = language
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CodeBlockDecoration else { return false }
        return isFirst == other.isFirst && isLast == other.isLast && language == other.language
    }

    override var hash: Int { isFirst.hashValue ^ isLast.hashValue ^ language.hashValue }
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
    /// カーソルのあるセルの列。この列だけは元の文字を列の中に並べて見せている（`cellTexts` の中身は空）
    let liveColumn: Int?

    init(kind: Kind, layout: TableLayout, isLast: Bool, cellTexts: [NSAttributedString]? = nil, liveColumn: Int? = nil) {
        self.kind = kind
        self.layout = layout
        self.cellTexts = cellTexts
        self.isLast = isLast
        self.liveColumn = liveColumn
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableRowDecoration else { return false }
        return kind == other.kind && isLast == other.isLast && layout == other.layout && cellTexts == other.cellTexts
            && liveColumn == other.liveColumn
    }

    override var hash: Int { layout.hash }
}

/// 段落に付いた装飾を、テキストの下（背景・罫線）と上（アイコン・セル）に描く
final class BlockLayoutFragment: NSTextLayoutFragment {
    var decoration: NSObject?
    /// トグルの中身の字下げ。表や枠は本文の左端からこの分だけ右に描く
    var inset: CGFloat = 0

    private var padding: CGFloat { textLayoutManager?.textContainer?.lineFragmentPadding ?? 5 }
    private var containerWidth: CGFloat { textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width }
    private var availableWidth: CGFloat { containerWidth - padding * 2 - inset }
    /// 装飾を描く左端（テキストコンテナの座標）
    private var left: CGFloat { padding + inset }

    /// フラグメントの原点はインデント後の位置にあるので、装飾の左端（行頭の余白の内側）までの距離を求める
    private func textLeft(from point: CGPoint) -> CGFloat {
        point.x - layoutFragmentFrame.minX + left
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
        EmbedCard.cardRect(left: left, width: min(availableWidth, 640))
    }

    /// 表の各列の右端の x 座標（テキストコンテナの座標系）と、描画時の縮小率
    func columnEdges() -> (edges: [CGFloat], scale: CGFloat)? {
        guard let row = decoration as? TableRowDecoration else { return nil }
        let (widths, scale) = row.layout.scaledWidths(available: availableWidth)
        var x = left
        return (widths.map { x += $0; return x }, scale)
    }

    override var renderingSurfaceBounds: CGRect {
        guard decoration != nil else { return super.renderingSurfaceBounds }
        let full = CGRect(x: -layoutFragmentFrame.minX, y: 0, width: containerWidth, height: layoutFragmentFrame.height)
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
        case let code as CodeBlockDecoration:
            drawCodeBlock(code, at: point)
            super.draw(at: point, in: context)
        case let card as EmbedCard:
            // 元の文字は透明なので、カードだけを描く
            let rect = embedCardRect().offsetBy(dx: point.x - layoutFragmentFrame.minX, dy: point.y)
            MainActor.assumeIsolated { card.draw(in: rect) }
        case let toggle as ToggleDecoration:
            super.draw(at: point, in: context)
            drawCheckboxes(at: point)
            drawToggleHeader(toggle, at: point)
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
    func checkboxes() -> [(rect: CGRect, range: NSRange, state: CheckboxState)] {
        var result: [(CGRect, NSRange, CheckboxState)] = []
        for line in textLineFragments {
            line.attributedString.enumerateAttribute(.maCheckbox, in: line.characterRange) { value, range, _ in
                guard let raw = value as? String, let state = CheckboxState(rawValue: raw) else { return }
                let start = line.locationForCharacter(at: range.location).x
                let end = line.locationForCharacter(at: NSMaxRange(range)).x
                let bounds = line.typographicBounds
                // 文字の縦中央はベースラインから大文字の高さの半分だけ上
                let centerY = bounds.minY + line.glyphOrigin.y - NSFont.systemFont(ofSize: 15).capHeight / 2
                let size: CGFloat = 14
                let rect = CGRect(x: bounds.minX + (start + end - size) / 2, y: centerY - size / 2, width: size, height: size)
                result.append((rect, range, state))
            }
        }
        return result
    }

    private func drawCheckboxes(at point: CGPoint) {
        drawReplacements(at: point)
        for (rect, _, state) in checkboxes() {
            let box = rect.offsetBy(dx: point.x, dy: point.y)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
            switch state {
            case .done:
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
            case .partial:
                // 進行中は枠と横線をアクセント色で描き、灰色の枠の未着手と塗りつぶした完了の間に見せる
                path.lineWidth = 1.2
                NSColor.controlAccentColor.setStroke()
                path.stroke()
                let dash = NSBezierPath()
                dash.move(to: CGPoint(x: box.minX + 4, y: box.midY))
                dash.line(to: CGPoint(x: box.maxX - 4, y: box.midY))
                dash.lineWidth = 1.8
                dash.lineCapStyle = .round
                NSColor.controlAccentColor.setStroke()
                dash.stroke()
            case .open:
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
        fillBlockBackground(rect, color: box.color.withAlphaComponent(0.1), isFirst: box.isFirst, isLast: box.isLast)
    }

    /// 段落をまたいでつながる背景。先頭と末尾の段落だけ角を丸め、途中の段落は上下に伸ばした角丸を切り取って四角にする
    private func fillBlockBackground(_ rect: CGRect, color: NSColor, isFirst: Bool, isLast: Bool) {
        let radius: CGFloat = 6
        var shape = rect
        if !isFirst { shape.origin.y -= radius; shape.size.height += radius }
        if !isLast { shape.size.height += radius }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        color.setFill()
        NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCodeBlock(_ code: CodeBlockDecoration, at point: CGPoint) {
        let left = textLeft(from: point)
        let rect = CGRect(x: left, y: point.y, width: availableWidth, height: decoratedHeight)
        fillBlockBackground(rect, color: .quaternarySystemFill, isFirst: code.isFirst, isLast: code.isLast)

        guard let language = code.language, let line = textLineFragments.first else { return }
        let label = NSAttributedString(string: language, attributes: [
            .font: CodeBlockDecoration.languageFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        let size = label.size()
        // 最初の行の文字と縦中央を揃え、右端の余白の内側に置く
        let bounds = line.typographicBounds
        let font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        let center = point.y + bounds.minY + line.glyphOrigin.y - (font.ascender + font.descender) / 2
        label.draw(at: CGPoint(x: left + availableWidth - CodeBlockDecoration.padding + 4 - size.width,
                               y: center - size.height / 2))
    }

    nonisolated(unsafe) private static let chevronFont = NSFont.systemFont(ofSize: 15, weight: .semibold)

    private static func chevron(collapsed: Bool, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: collapsed ? "›" : "⌄", attributes: [.font: chevronFont, .foregroundColor: color])
    }

    /// 折りたためるコールアウトの右上の開閉の印（トグルは行頭の ▸/▾）の、クリックを受ける範囲
    /// （横はテキストコンテナ、縦はフラグメントの上端からの座標）
    func foldButtonRect() -> CGRect? {
        if decoration is ToggleDecoration {
            let side: CGFloat = 22
            return CGRect(x: left + ToggleBlock.triangleCenter - side / 2, y: firstLineTextCenter(from: .zero) - side / 2, width: side, height: side)
        }
        guard let box = decoration as? BoxDecoration, box.isFirst, box.foldable else { return nil }
        let size = Self.chevron(collapsed: box.collapsed, color: box.color).size()
        let center = CGPoint(x: left + availableWidth - 14 - size.width / 2, y: firstLineTextCenter(from: .zero))
        let side: CGFloat = 24
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    private func drawBoxHeader(_ box: BoxDecoration, at point: CGPoint) {
        guard box.isFirst, !box.isQuote else { return }
        let center = firstLineTextCenter(from: point)
        let left = textLeft(from: point) + 14
        var titleLeft = left
        if let icon = box.icon {
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
            titleLeft += 24
        }
        if let title = box.fallbackTitle {
            let string = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: box.color,
            ])
            string.draw(at: CGPoint(x: titleLeft, y: center - string.size().height / 2))
        }
        if box.foldable {
            let chevron = Self.chevron(collapsed: box.collapsed, color: box.color)
            let size = chevron.size()
            chevron.draw(at: CGPoint(x: textLeft(from: point) + availableWidth - 14 - size.width,
                                     y: center - size.height / 2))
        }
    }

    /// トグルの見出し行の ▸/▾ と、タイトルが空のときの薄い文字
    private func drawToggleHeader(_ toggle: ToggleDecoration, at point: CGPoint) {
        let center = firstLineTextCenter(from: point)
        let left = textLeft(from: point)
        ToggleBlock.drawTriangle(collapsed: toggle.collapsed, center: CGPoint(x: left + ToggleBlock.triangleCenter, y: center))
        guard let placeholder = toggle.placeholder else { return }
        let string = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        string.draw(at: CGPoint(x: left + ToggleBlock.indent, y: center - string.size().height / 2))
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
            fragment.inset = paragraph.attributedString.attribute(.maInset, at: 0, effectiveRange: nil) as? CGFloat ?? 0
        }
        return fragment
    }
}

/// 表の編集中のセルの <br> を、表示のうえだけ行区切りにする。文字数は変えないので、文書の位置との対応はそのまま
final class TableLineBreakDelegate: NSObject, NSTextContentStorageDelegate {
    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let storage = textContentStorage.textStorage, NSMaxRange(range) <= storage.length else { return nil }
        var breaks: [NSRange] = []
        storage.enumerateAttribute(.maLineBreak, in: range) { value, found, _ in
            if value != nil { breaks.append(NSRange(location: found.location - range.location, length: found.length)) }
        }
        guard !breaks.isEmpty else { return nil }
        let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        // 置き換えた文字は元の文字の属性を引き継ぐ
        for found in breaks {
            paragraph.replaceCharacters(in: found, with: String(repeating: "\u{2028}", count: found.length))
        }
        return NSTextParagraph(attributedString: paragraph)
    }
}
