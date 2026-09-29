import AppKit

/// 本文を最大幅に収め、ウィンドウが広いときは中央に寄せる。
/// 表の列幅のドラッグ、行の追加ボタン、チェックボックスのクリックを受け持つ
final class EditorTextView: NSTextView {
    private let maxTextWidth: CGFloat = 760

    private struct ColumnDrag {
        let layout: TableLayout
        let column: Int
        let startX: CGFloat
        let startWidth: CGFloat
        let scale: CGFloat
    }
    private var columnDrag: ColumnDrag?
    private var hoverTrackingArea: NSTrackingArea?
    private let addRowButton = NSButton()
    private var hoveredTable: TableLayout?
    private lazy var blockDrag = BlockDragController(textView: self)

    // init を上書きすると init(usingTextLayoutManager:) が継承されなくなるので、配置された時点で準備する
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard addRowButton.superview == nil else { return }
        addRowButton.bezelStyle = .circular
        addRowButton.controlSize = .small
        addRowButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "行を追加")
        addRowButton.imagePosition = .imageOnly
        addRowButton.toolTip = "行を追加"
        addRowButton.target = self
        addRowButton.action = #selector(addRow(_:))
        addRowButton.isHidden = true
        addSubview(addRowButton)
        addSubview(blockDrag.handle)
        addSubview(blockDrag.indicator)
    }

    // ノートを切り替えたときも、ブロックの読み直しが要る
    override var string: String {
        didSet { blockDrag.textDidChange() }
    }

    /// 本文の幅が変わったとき。表の列幅（収まらないときの縮小）を計算し直すのに使う
    var onTextWidthChange: (() -> Void)?

    var textWidth: CGFloat {
        (textContainer?.size.width ?? 0) - (textContainer?.lineFragmentPadding ?? 5) * 2
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = textWidth
        super.setFrameSize(newSize)
        let horizontal = max(32, (newSize.width - maxTextWidth) / 2)
        if textContainerInset.width != horizontal {
            textContainerInset = NSSize(width: horizontal, height: 32)
        }
        if textWidth != oldWidth { onTextWidthChange?() }
    }

    override func didChangeText() {
        super.didChangeText()
        hideAddRowButton()
        blockDrag.textDidChange()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        updateAddRowButton(at: point)
        blockDrag.hover(at: point)
        if columnEdge(at: point) != nil {
            NSCursor.resizeLeftRight.set()
        } else if checkbox(at: point) != nil {
            NSCursor.pointingHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideAddRowButton()
        blockDrag.hideHandle()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (range, checked) = checkbox(at: point) {
            // カーソルを動かさずにチェックを切り替える
            replace(NSRange(location: range.location + 1, length: 1), with: checked ? " " : "x",
                    actionName: checked ? "チェックを外す" : "チェック")
            return
        }
        guard let hit = columnEdge(at: point) else { return super.mouseDown(with: event) }
        // 境界を掴んだときはカーソルを表に入れない（入れるとソース表示に切り替わる）。
        // ドラッグ中は表を作り直しながら描くので、位置が定まらない行の追加ボタンは隠す
        hideAddRowButton()
        columnDrag = ColumnDrag(
            layout: hit.layout, column: hit.column, startX: point.x,
            startWidth: hit.layout.columnWidths[hit.column], scale: hit.scale
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = columnDrag else { return super.mouseDragged(with: event) }
        NSCursor.resizeLeftRight.set()
        let x = convert(event.locationInWindow, from: nil).x
        drag.layout.columnWidths[drag.column] = TableLayout.snapped(drag.startWidth + (x - drag.startX) / drag.scale)
        redraw(drag.layout.tableRange)
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = columnDrag else { return super.mouseUp(with: event) }
        columnDrag = nil
        // 区切り行の `-` の数として幅を保存する
        let range = drag.layout.separatorRange
        let line = drag.layout.separatorLine()
        guard (string as NSString).substring(with: range) != line else { return redraw(drag.layout.tableRange) }
        replace(range, with: line, actionName: "列幅の変更")
    }

    @objc private func addRow(_ sender: Any?) {
        guard let layout = hoveredTable else { return }
        setSelectedRange(NSRange(location: appendRow(to: layout), length: 0))
        window?.makeFirstResponder(self)
    }

    /// 表の最終行の後ろに空の行を足し、新しい行の最初のセル（入力が入る位置）を返す
    func appendRow(to layout: TableLayout) -> Int {
        let cells = String(repeating: "   |", count: layout.columnWidths.count)
        let insertion = layout.endOfLastRow
        replace(NSRange(location: insertion, length: 0), with: "\n|" + cells, actionName: "行を追加")
        return insertion + 3
    }

    /// 通常の編集と同じ経路で書き換える。取り消し・自動保存・再装飾がそのまま動く
    func replace(_ range: NSRange, with replacement: String, actionName: String) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        undoManager?.setActionName(actionName)
    }

    /// 文字は変えずに「属性が変わった」とだけ通知し、その範囲のフラグメントを作り直させる。
    /// invalidateLayout(for:) だけでは再描画されなかった
    private func redraw(_ range: NSRange) {
        guard let textStorage, NSMaxRange(range) <= textStorage.length else { return }
        textStorage.beginEditing()
        textStorage.edited(.editedAttributes, range: range, changeInLength: 0)
        textStorage.endEditing()
    }

    // MARK: - 当たり判定

    private func containerPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    }

    private func fragment(at location: CGPoint) -> BlockLayoutFragment? {
        guard let fragment = textLayoutManager?.textLayoutFragment(for: location) as? BlockLayoutFragment,
              fragment.layoutFragmentFrame.minY...(fragment.layoutFragmentFrame.minY + fragment.decoratedHeight) ~= location.y
        else { return nil }
        return fragment
    }

    /// マウス位置が表の列の境界（右端から ±4pt）にあれば、その表と列を返す
    private func columnEdge(at point: NSPoint) -> (layout: TableLayout, column: Int, scale: CGFloat)? {
        let location = containerPoint(point)
        guard let fragment = fragment(at: location),
              let row = fragment.decoration as? TableRowDecoration, row.kind != .separator,
              let (edges, scale) = fragment.columnEdges(),
              let column = edges.firstIndex(where: { abs($0 - location.x) <= 4 })
        else { return nil }
        return (row.layout, column, scale)
    }

    /// マウス位置にチェックボックスがあれば、`[ ]` の文書内の範囲とチェック状態を返す
    private func checkbox(at point: NSPoint) -> (range: NSRange, checked: Bool)? {
        let location = containerPoint(point)
        guard let fragment = fragment(at: location),
              let content = textLayoutManager?.textContentManager
        else { return nil }
        let local = CGPoint(x: location.x - fragment.layoutFragmentFrame.minX, y: location.y - fragment.layoutFragmentFrame.minY)
        guard let hit = fragment.checkboxes().first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(local) }) else { return nil }
        let paragraphStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return (NSRange(location: paragraphStart + hit.range.location, length: hit.range.length), hit.checked)
    }

    // MARK: - 行の追加ボタン

    /// 表の上にマウスがあるあいだ、表の下端の中央にボタンを出す
    private func updateAddRowButton(at point: NSPoint) {
        guard columnDrag == nil else { return }
        if !addRowButton.isHidden, addRowButton.frame.insetBy(dx: -8, dy: -8).contains(point) { return }
        let location = containerPoint(point)
        guard let fragment = fragment(at: location), let row = fragment.decoration as? TableRowDecoration,
              location.x <= fragment.columnEdges()?.edges.last ?? 0
        else { return hideAddRowButton() }
        placeAddRowButton(for: row.layout)
    }

    private func placeAddRowButton(for layout: TableLayout) {
        guard let layoutManager = textLayoutManager, let content = layoutManager.textContentManager,
              let lastCell = layout.rows.last?.first,
              let lastRow = content.location(content.documentRange.location, offsetBy: lastCell.location),
              let fragment = layoutManager.textLayoutFragment(for: lastRow) as? BlockLayoutFragment,
              let edges = fragment.columnEdges()?.edges
        else { return hideAddRowButton() }
        hoveredTable = layout
        let size: CGFloat = 20
        let left = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5)
        let right = textContainerOrigin.x + (edges.last ?? 0)
        let bottom = textContainerOrigin.y + fragment.layoutFragmentFrame.minY + fragment.decoratedHeight
        addRowButton.frame = CGRect(x: (left + right - size) / 2, y: bottom - size / 2, width: size, height: size)
        addRowButton.isHidden = false
    }

    private func hideAddRowButton() {
        addRowButton.isHidden = true
        hoveredTable = nil
    }
}

final class EditorViewController: NSViewController, NSTextViewDelegate, NSMenuItemValidation {
    var onChange: ((String) -> Void)?

    private let textView = EditorTextView(usingTextLayoutManager: true)
    private let placeholder = NSTextField(labelWithString: "ノートを選択してください")
    private let styler = MarkdownStyler()
    private let layoutDelegate = BlockLayoutDelegate()
    private var activeLines = NSRange(location: NSNotFound, length: 0)
    /// 直近の装飾で見つかった表。表の中での Tab や Enter の移動先を求めるのに使う
    private var tables: [TableLayout] = []

    private static let sourceModeKey = "sourceMode"
    /// ソース表示（装飾なし）かどうか。⌘E で切り替え、次回の起動にも引き継ぐ
    private var sourceMode = AppDefaults.shared.bool(forKey: sourceModeKey)

    override func loadView() {
        textView.delegate = self
        textView.textLayoutManager?.delegate = layoutDelegate
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.onTextWidthChange = { [weak self] in self?.restyle(force: true) }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView

        // NSScrollView に直接載せたサブビューは制約どおりに置かれないので、入れ物のビューに並べる
        let container = NSView()
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        show(nil)
    }

    func show(_ document: OpenDocument?) {
        placeholder.isHidden = document != nil
        textView.isEditable = document != nil
        textView.string = document?.text ?? ""
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        restyle(force: true)
        textView.scrollToBeginningOfDocument(nil)
        if document != nil { view.window?.makeFirstResponder(textView) }
    }

    @objc func toggleSourceMode(_ sender: Any?) {
        sourceMode.toggle()
        AppDefaults.shared.set(sourceMode, forKey: Self.sourceModeKey)
        restyle(force: true)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSourceMode(_:)) {
            menuItem.state = sourceMode ? .on : .off
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        // 日本語の変換中（未確定文字あり）は保存も装飾もしない。確定時にもう一度呼ばれる
        guard !textView.hasMarkedText() else { return }
        onChange?(textView.string)
        restyle(force: true)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        restyle(force: false)
    }

    /// カーソルのある行だけ記号を表示し、それ以外の行では隠す
    private func restyle(force: Bool) {
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        let length = storage.length
        let selection = textView.selectedRange()
        let location = min(selection.location, length)
        let lines = (storage.string as NSString).lineRange(
            for: NSRange(location: location, length: min(selection.length, length - location))
        )
        guard force || lines != activeLines else { return }
        activeLines = lines
        tables = styler.apply(to: storage, activeRange: lines, availableWidth: textView.textWidth, sourceMode: sourceMode)
        textView.typingAttributes = styler.baseAttributes
    }

    // MARK: - 表の中のキー操作

    /// Tab で次のセル、Shift+Tab で前のセル、Enter で下の行、Shift+Enter でセル内の改行（<br>）
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !sourceMode, textView.selectedRange().length == 0 else { return false }
        let caret = textView.selectedRange().location
        guard let table = tables.first(where: { NSLocationInRange(caret, $0.tableRange) || caret == $0.endOfLastRow }),
              let (row, column) = table.cell(containing: caret)
        else { return false }
        let columns = table.columnWidths.count
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            if column + 1 < min(columns, table.rows[row].count) {
                moveCaret(to: table, row: row, column: column + 1)
            } else if row + 1 < table.rows.count {
                moveCaret(to: table, row: row + 1, column: 0)
            } else {
                moveCaret(toNewRowOf: table, column: 0)
            }
        case #selector(NSResponder.insertBacktab(_:)):
            if column > 0 {
                moveCaret(to: table, row: row, column: column - 1)
            } else if row > 0 {
                moveCaret(to: table, row: row - 1, column: min(columns, table.rows[row - 1].count) - 1)
            }
        case #selector(NSResponder.insertNewline(_:)) where NSApp.currentEvent?.modifierFlags.contains(.shift) == true,
             #selector(NSResponder.insertLineBreak(_:)):
            self.textView.replace(NSRange(location: caret, length: 0), with: "<br>", actionName: "セル内の改行")
            textView.setSelectedRange(NSRange(location: caret + 4, length: 0))
        case #selector(NSResponder.insertNewline(_:)):
            if row + 1 < table.rows.count {
                moveCaret(to: table, row: row + 1, column: column)
            } else {
                moveCaret(toNewRowOf: table, column: column)
            }
        default:
            return false
        }
        return true
    }

    /// 区切り行は高さ 0 で隠しているので、カーソルが入りそうになったら上下の行へ飛ばす
    func textView(
        _ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange
    ) -> NSRange {
        guard !sourceMode, new.length == 0,
              let table = tables.first(where: {
                  $0.separatorRange.location <= new.location && new.location <= NSMaxRange($0.separatorRange)
              })
        else { return new }
        let column = table.cell(containing: old.location)?.column ?? 0
        if new.location > old.location, table.rows.count > 1 {
            return NSRange(location: caretLocation(in: table, row: 1, column: column), length: 0)
        }
        return NSRange(location: caretLocation(in: table, row: 0, column: column), length: 0)
    }

    private func moveCaret(to table: TableLayout, row: Int, column: Int) {
        textView.setSelectedRange(NSRange(location: caretLocation(in: table, row: row, column: column), length: 0))
    }

    private func moveCaret(toNewRowOf table: TableLayout, column: Int) {
        let location = textView.appendRow(to: table)
        // 行を足すと装飾がかけ直され、表の情報も新しくなる
        guard let updated = tables.first(where: { NSLocationInRange(location, $0.tableRange) }) else { return }
        moveCaret(to: updated, row: updated.rows.count - 1, column: column)
    }

    /// セルの文字の末尾。空のセルは縦棒の直後の空白の後ろ
    private func caretLocation(in table: TableLayout, row: Int, column: Int) -> Int {
        let cells = table.rows[row]
        let cell = cells[min(column, cells.count - 1)]
        let string = textView.string as NSString
        var end = NSMaxRange(cell)
        while end > cell.location, [0x20, 0x09].contains(string.character(at: end - 1)) { end -= 1 }
        return end == cell.location ? cell.location + min(1, cell.length) : end
    }
}
