import AppKit

extension NSAttributedString.Key {
    /// 段落の先頭に付け、レイアウトフラグメントに描かせる装飾を渡す
    static let maBlock = NSAttributedString.Key("ma.block")
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
    let tableRange: NSRange

    init(columnWidths: [CGFloat], alignments: [NSTextAlignment], separatorRange: NSRange, tableRange: NSRange) {
        self.columnWidths = columnWidths
        self.alignments = alignments
        self.separatorRange = separatorRange
        self.tableRange = tableRange
    }

    /// 列幅の合計が本文の幅を超えるときは、比率を保って縮める
    func scaledWidths(available: CGFloat) -> (widths: [CGFloat], scale: CGFloat) {
        let scale = min(1, available / max(columnWidths.reduce(0, +), 1))
        return (columnWidths.map { floor($0 * scale) }, scale)
    }

    /// 現在の列幅を `-` の数に直した区切り行
    func separatorLine() -> String {
        let cells = columnWidths.enumerated().map { column, width -> String in
            let count = max(3, Int(((width - TableRowDecoration.cellPadding * 2) / Self.dashWidth).rounded()))
            switch column < alignments.count ? alignments[column] : .left {
            case .center: return ":" + String(repeating: "-", count: count - 2) + ":"
            case .right: return String(repeating: "-", count: count - 1) + ":"
            default: return String(repeating: "-", count: count)
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

    let kind: Kind
    let cells: [String]
    let layout: TableLayout
    let isLast: Bool

    init(kind: Kind, cells: [String], layout: TableLayout, isLast: Bool) {
        self.kind = kind
        self.cells = cells
        self.layout = layout
        self.isLast = isLast
    }
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
        case let row as TableRowDecoration:
            drawTableRow(row, at: point)
        default:
            super.draw(at: point, in: context)
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

        let font = row.kind == .header ? TableRowDecoration.headerFont : TableRowDecoration.bodyFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        var x = left
        for (column, width) in widths.enumerated() {
            defer { x += width }
            guard column < row.cells.count else { continue }
            let style = NSMutableParagraphStyle()
            style.alignment = column < row.layout.alignments.count ? row.layout.alignments[column] : .left
            style.lineBreakMode = .byTruncatingTail
            let cell = NSAttributedString(string: row.cells[column], attributes: [
                .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: style,
            ])
            let padding = TableRowDecoration.cellPadding
            cell.draw(
                with: CGRect(x: x + padding, y: point.y + (height - lineHeight) / 2,
                             width: max(0, width - padding * 2), height: lineHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
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
