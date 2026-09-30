import AppKit

/// ブロックの左に出すつまみ（⋮⋮）。押してドラッグするとブロックを動かせる
final class BlockHandleView: NSView {
    var onDragBegin: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onDragEnd: ((NSEvent) -> Void)?
    private var isHovered = false

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        NSColor.tertiaryLabelColor.setFill()
        let size: CGFloat = 2.5, gap: CGFloat = 3.5
        let originX = bounds.midX - (size * 2 + gap) / 2
        let originY = bounds.midY - (size * 3 + gap * 2) / 2
        for column in 0..<2 {
            for row in 0..<3 {
                let rect = NSRect(x: originX + CGFloat(column) * (size + gap), y: originY + CGFloat(row) * (size + gap), width: size, height: size)
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { NSCursor.closedHand.set(); onDragBegin?(event) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    override func mouseUp(with event: NSEvent) {
        onDragEnd?(event)
        // 離した位置がつまみの外なら、本文の I ビームに戻す
        let inside = !isHidden && bounds.contains(convert(event.locationInWindow, from: nil))
        (inside ? NSCursor.openHand : NSCursor.iBeam).set()
    }
}

/// ブロックのつまみの表示とドラッグを受け持つ。本文は素の Markdown のまま、行を入れ替える
@MainActor
final class BlockDragController {
    private unowned let textView: EditorTextView
    let handle = BlockHandleView()
    let indicator = NSView()

    private var mover: BlockMover?
    private var lineStarts: [Int] = []
    private var hoveredBlock: MarkdownBlock?

    private struct Drag {
        let block: MarkdownBlock
        /// つかんだ位置からブロックの文字の左端までの距離。落としたときの階層を決めるのに使う
        let grabOffset: CGFloat
        var drop: BlockMover.Drop?
    }
    private var drag: Drag?

    var isDragging: Bool { drag != nil }

    init(textView: EditorTextView) {
        self.textView = textView
        handle.isHidden = true
        handle.toolTip = "ドラッグして移動"
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        indicator.layer?.cornerRadius = 1
        indicator.isHidden = true
        handle.onDragBegin = { [unowned self] in beginDrag($0) }
        handle.onDrag = { [unowned self] in continueDrag($0) }
        handle.onDragEnd = { [unowned self] _ in endDrag() }
    }

    func textDidChange() {
        mover = nil
        guard drag == nil else { return }
        hideHandle()
    }

    func hideHandle() {
        guard drag == nil else { return }
        handle.isHidden = true
        hoveredBlock = nil
    }

    /// つまみの上か。NSTextView の mouseMoved が I ビームに戻すので、EditorTextView がカーソルを付け直すのに使う
    func isOnHandle(_ point: NSPoint) -> Bool {
        !handle.isHidden && handle.frame.contains(point)
    }

    /// マウスのある行のブロックの先頭行の左に、つまみを出す
    func hover(at point: NSPoint) {
        guard drag == nil, !textView.hasMarkedText() else { return }
        if !handle.isHidden, handle.frame.insetBy(dx: -4, dy: -4).contains(point) { return }
        let mover = currentMover()
        guard let line = line(at: point), let block = mover.block(containing: line),
              let position = handlePosition(for: block)
        else { return hideHandle() }
        hoveredBlock = block
        // トグルの最初の行は記号の左に ▸/▾ があるので、つまみをその左に出す
        let toggleWidth = textView.isListToggle(startingAt: lineStarts[block.lines.lowerBound]) ? ListToggle.buttonSize + 2 : 0
        handle.frame = NSRect(x: position.x - 22 - toggleWidth, y: position.y - 11, width: 18, height: 22)
        handle.isHidden = false
    }

    // MARK: - ドラッグ

    private func beginDrag(_ event: NSEvent) {
        guard let block = hoveredBlock, let position = handlePosition(for: block) else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        drag = Drag(block: block, grabOffset: position.x - point.x)
    }

    private func continueDrag(_ event: NSEvent) {
        guard var drag else { return }
        textView.autoscroll(with: event)
        let point = textView.convert(event.locationInWindow, from: nil)
        handle.frame.origin.y = point.y - handle.frame.height / 2
        drag.drop = nearestDrop(to: point, for: drag)
        self.drag = drag
    }

    private func endDrag() {
        defer {
            drag = nil
            indicator.isHidden = true
            hideHandle()
        }
        guard let drag, let drop = drag.drop, let (text, location) = currentMover().move(drag.block, to: drop) else { return }
        // 変わった部分だけを置き換える（同じ文字が続く前後は触らない）
        let old = textView.string as NSString, new = text as NSString
        var prefix = 0
        while prefix < min(old.length, new.length), old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(old.length, new.length) - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        textView.replace(range, with: new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix)),
                         actionName: "ブロックの移動")
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.window?.makeFirstResponder(textView)
    }

    /// マウスにいちばん近いブロックの境目と、リスト項目なら横位置に合う階層
    private func nearestDrop(to point: NSPoint, for drag: Drag) -> BlockMover.Drop? {
        let mover = currentMover()
        var best: (line: Int, y: CGFloat)?
        for line in mover.dropLines {
            let range = drag.block.lines
            if range.contains(line) && line != range.lowerBound { continue }
            // たたんで隠した行の間には落とさない（落としたブロックが見えなくなる）
            if line < lineStarts.count, textView.isFolded(lineStarts[line]) { continue }
            guard let y = gapY(before: line) else { continue }
            if best == nil || abs(y - point.y) < abs(best!.y - point.y) { best = (line, y) }
        }
        guard let best else { indicator.isHidden = true; return nil }

        let left = textLeft
        var x = left
        var indent: String?
        let choices = mover.indentChoices(for: drag.block, at: best.line) { line in
            line < lineStarts.count && textView.isFolded(lineStarts[line])
        }
        if !choices.isEmpty {
            let target = point.x + drag.grabOffset
            let (base, step) = listMetrics()
            let positions = choices.map { (indent: $0, x: base + CGFloat(Self.depth($0)) * step) }
            let chosen = positions.min { abs($0.x - target) < abs($1.x - target) }!
            indent = chosen.indent
            x = chosen.x
        }
        let drop = BlockMover.Drop(line: best.line, indent: indent)
        guard mover.move(drag.block, to: drop) != nil else { indicator.isHidden = true; return nil }
        indicator.frame = NSRect(x: x, y: best.y - 1, width: max(40, textRight - x), height: 2)
        indicator.isHidden = false
        return drop
    }

    // MARK: - 位置の計算

    private func currentMover() -> BlockMover {
        if let mover { return mover }
        let mover = BlockMover(textView.string)
        self.mover = mover
        var starts: [Int] = []
        var offset = 0
        for line in mover.lines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }
        lineStarts = starts
        return mover
    }

    private var textLeft: CGFloat {
        textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 5)
    }

    private var textRight: CGFloat {
        textLeft + textView.textWidth
    }

    private func line(at point: NSPoint) -> Int? {
        let origin = textView.textContainerOrigin
        let location = CGPoint(x: 1, y: point.y - origin.y)
        guard let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager,
              let fragment = layoutManager.textLayoutFragment(for: location),
              location.y <= fragment.layoutFragmentFrame.maxY
        else { return nil }
        let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return lineStarts.lastIndex { $0 <= offset }
    }

    private func fragment(forLine line: Int) -> NSTextLayoutFragment? {
        guard line < lineStarts.count, let layoutManager = textView.textLayoutManager,
              let content = layoutManager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: lineStarts[line])
        else { return nil }
        return layoutManager.textLayoutFragment(for: location)
    }

    private func bottom(of fragment: NSTextLayoutFragment) -> CGFloat {
        fragment.layoutFragmentFrame.minY + ((fragment as? BlockLayoutFragment)?.decoratedHeight ?? fragment.layoutFragmentFrame.height)
    }

    /// つまみを置く位置（文字の左端と、先頭行の文字の縦中央）。
    /// リスト項目は階層ごとの行頭、ほかは本文の左端（コールアウトは枠の内側の余白ぶん文字が右にある）
    private func handlePosition(for block: MarkdownBlock) -> NSPoint? {
        guard let fragment = fragment(forLine: block.lines.lowerBound), let first = fragment.textLineFragments.first else { return nil }
        let origin = textView.textContainerOrigin
        let bounds = first.typographicBounds
        let indentLength = (block.indent as NSString).length
        let x = first.locationForCharacter(at: min(indentLength, first.characterRange.length)).x
        let centerY = bounds.minY + first.glyphOrigin.y - NSFont.systemFont(ofSize: 15).capHeight / 2
        return NSPoint(
            x: block.kind == .listItem ? origin.x + fragment.layoutFragmentFrame.minX + bounds.minX + x : textLeft,
            y: origin.y + fragment.layoutFragmentFrame.minY + centerY
        )
    }

    /// `line` の手前の境目の y。前のブロックの下端と、そのブロックの上端の中間
    private func gapY(before line: Int) -> CGFloat? {
        let mover = currentMover()
        let origin = textView.textContainerOrigin.y
        let previous = (0..<line).last { !BlockMover.isBlank(mover.lines[$0]) }
        let previousBottom = previous.flatMap { fragment(forLine: $0) }.map(bottom(of:))
        if line < mover.lines.count, !BlockMover.isBlank(mover.lines[line]), let fragment = fragment(forLine: line) {
            let top = fragment.layoutFragmentFrame.minY
            return origin + (previousBottom.map { ($0 + top) / 2 } ?? top)
        }
        return previousBottom.map { origin + $0 + 4 }
    }

    /// 最上位のリスト項目の左端と、1段の幅。文書の中の階層の違う項目どうしの位置から測り、なければ本文の左端と 24pt
    private func listMetrics() -> (base: CGFloat, step: CGFloat) {
        let items = currentMover().blocks.filter { $0.kind == .listItem }
        let base = items.first { $0.indent.isEmpty }.flatMap { handlePosition(for: $0)?.x } ?? textLeft
        guard let nested = items.first(where: { Self.depth($0.indent) > 0 }), let nestedX = handlePosition(for: nested)?.x,
              nestedX > base
        else { return (base, 24) }
        return (base, (nestedX - base) / CGFloat(Self.depth(nested.indent)))
    }

    /// 行頭の空白が何段ぶんか（タブ1つ、または空白2つで1段）
    private static func depth(_ indent: String) -> Int {
        (indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } + 1) / 2
    }
}
