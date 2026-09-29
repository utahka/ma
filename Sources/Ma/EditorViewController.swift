import AppKit

/// 本文を最大幅に収め、ウィンドウが広いときは中央に寄せる。表の列の境界はドラッグで幅を変えられる
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let horizontal = max(32, (newSize.width - maxTextWidth) / 2)
        if textContainerInset.width != horizontal {
            textContainerInset = NSSize(width: horizontal, height: 32)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if columnEdge(at: convert(event.locationInWindow, from: nil)) != nil {
            NSCursor.resizeLeftRight.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = columnEdge(at: point) else { return super.mouseDown(with: event) }
        // 境界を掴んだときはカーソルを表に入れない（入れるとソース表示に切り替わる）
        columnDrag = ColumnDrag(
            layout: hit.layout, column: hit.column, startX: point.x,
            startWidth: hit.layout.columnWidths[hit.column], scale: hit.scale
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = columnDrag else { return super.mouseDragged(with: event) }
        NSCursor.resizeLeftRight.set()
        let x = convert(event.locationInWindow, from: nil).x
        drag.layout.columnWidths[drag.column] = max(
            TableLayout.minimumWidth, drag.startWidth + (x - drag.startX) / drag.scale
        )
        invalidateLayout(for: drag.layout.tableRange)
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = columnDrag else { return super.mouseUp(with: event) }
        columnDrag = nil
        // 区切り行の `-` の数として幅を保存する。通常の編集と同じ経路なので取り消しや自動保存も効く
        let range = drag.layout.separatorRange
        let line = drag.layout.separatorLine()
        guard (string as NSString).substring(with: range) != line,
              shouldChangeText(in: range, replacementString: line)
        else { return invalidateLayout(for: drag.layout.tableRange) }
        textStorage?.replaceCharacters(in: range, with: line)
        didChangeText()
        undoManager?.setActionName("列幅の変更")
    }

    /// マウス位置が表の列の境界（右端から ±4pt）にあれば、その表と列を返す
    private func columnEdge(at point: NSPoint) -> (layout: TableLayout, column: Int, scale: CGFloat)? {
        let location = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        guard let fragment = textLayoutManager?.textLayoutFragment(for: location) as? BlockLayoutFragment,
              let row = fragment.decoration as? TableRowDecoration, row.kind != .separator,
              fragment.layoutFragmentFrame.minY...(fragment.layoutFragmentFrame.minY + fragment.decoratedHeight) ~= location.y,
              let (edges, scale) = fragment.columnEdges(),
              let column = edges.firstIndex(where: { abs($0 - location.x) <= 4 })
        else { return nil }
        return (row.layout, column, scale)
    }

    private func invalidateLayout(for range: NSRange) {
        guard let layoutManager = textLayoutManager,
              let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end)
        else { return }
        layoutManager.invalidateLayout(for: textRange)
        layoutManager.textViewportLayoutController.layoutViewport()
    }
}

final class EditorViewController: NSViewController, NSTextViewDelegate {
    var onChange: ((String) -> Void)?

    private let textView = EditorTextView(usingTextLayoutManager: true)
    private let placeholder = NSTextField(labelWithString: "ノートを選択してください")
    private let styler = MarkdownStyler()
    private let layoutDelegate = BlockLayoutDelegate()
    private var activeLines = NSRange(location: NSNotFound, length: 0)

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

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView

        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        view = scrollView
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
        styler.apply(to: storage, activeRange: lines)
        textView.typingAttributes = styler.baseAttributes
    }
}
