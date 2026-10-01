import AppKit

/// 本文中のリンクの行き先
enum LinkTarget {
    /// `[[ノート名]]`
    case note(String)
    /// `[表示名](URL)`
    case url(String)
}

/// 本文を最大幅に収め、ウィンドウが広いときは中央に寄せる。
/// 表の列幅のドラッグ、行の追加ボタン、チェックボックスとリンクのクリックを受け持つ
final class EditorTextView: NSTextView {
    private let maxTextWidth: CGFloat = 760

    /// コメントを付けられる選択範囲。前後の空白を除き、1行に収まり `==` を含まない選択だけを返す
    var commentableSelection: NSRange? {
        let string = self.string as NSString
        var range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= string.length else { return nil }
        let whitespace = CharacterSet.whitespaces
        func isSpace(_ index: Int) -> Bool {
            string.substring(with: NSRange(location: index, length: 1)).unicodeScalars.allSatisfy(whitespace.contains)
        }
        while range.length > 0, isSpace(range.location) { range.location += 1; range.length -= 1 }
        while range.length > 0, isSpace(NSMaxRange(range) - 1) { range.length -= 1 }
        let selected = string.substring(with: range)
        // `==` を含むと、付けたハイライトの範囲が崩れる
        guard range.length > 0, selected.rangeOfCharacter(from: .newlines) == nil, !selected.contains("==") else { return nil }
        return range
    }

    /// 文字を選んで右クリックしたとき、メニューの先頭に「コメントを追加…」を出す
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if let menu, commentableSelection != nil {
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(withTitle: "コメントを追加…", action: #selector(EditorAreaViewController.addAIComment(_:)),
                            keyEquivalent: "", at: 0)
        }
        return menu
    }

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
    private let commentPopover = AICommentPopover()
    let propertiesView = PropertiesView()

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
        propertiesView.isHidden = true
        addSubview(propertiesView)
        NotificationCenter.default.addObserver(self, selector: #selector(embedImageDidLoad(_:)), name: .maEmbedImageLoaded, object: nil)
    }

    /// Link Embed のカードの画像が届いたら、その画像を使うカードを描き直す
    @objc private func embedImageDidLoad(_ notification: Notification) {
        guard let image = notification.object as? String, let storage = textStorage else { return }
        storage.enumerateAttribute(.maBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let card = value as? EmbedCard, card.image == image || card.favicon == image else { return }
            redraw(range)
        }
    }

    /// プロパティ欄を、隠したフロントマターの最初の行（文書の先頭）に重ねる
    func placeProperties(height: CGFloat?) {
        guard let height else { propertiesView.isHidden = true; return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        propertiesView.frame = NSRect(x: textContainerOrigin.x + padding, y: textContainerOrigin.y, width: textWidth, height: height)
        propertiesView.isHidden = false
    }

    // ノートを切り替えたときも、ブロックの読み直しが要る
    override var string: String {
        didSet {
            blockDrag.textDidChange()
            closeCommentPopover()
        }
    }

    /// リンクをクリックしたとき。⌘クリックなら `newTab` が true
    var onOpenLink: ((LinkTarget, _ newTab: Bool) -> Void)?

    /// 本文の幅が変わったとき。表の列幅（収まらないときの縮小）を計算し直すのに使う
    var onTextWidthChange: (() -> Void)?

    /// 列幅のドラッグ中に幅が変わったとき。セルの文字を新しい列の位置へ送り直すのに使う
    var onColumnDrag: (() -> Void)?

    /// 折りたためるコールアウトの開閉の印をクリックしたとき。引数は見出し行の先頭の位置
    var onToggleFold: ((Int) -> Void)?

    /// ドラッグ中の表の区切り行の位置と列幅。区切り行を書き換えるのは離したときだけなので、それまでは装飾にこの幅を渡す
    var draggedWidths: (separator: Int, widths: [CGFloat])? {
        columnDrag.map { ($0.layout.separatorRange.location, $0.layout.columnWidths) }
    }

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
        closeCommentPopover()
    }

    /// 外部の変更で本文を直接差し替えたとき。編集ではないので didChangeText は呼ばず（保存し直さない）、ブロックの読み直しだけ行う
    func textDidReload() {
        hideAddRowButton()
        blockDrag.textDidChange()
        closeCommentPopover()
    }

    // カーソルが入るとその行は記号とコメントがそのまま見えるので、吹き出しは閉じる
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        closeCommentPopover()
    }

    /// 直近に受けた Return（テンキーの Enter を含む）の keyDown に Shift が付いていたか。
    /// 日本語入力（IME）を通すとキー入力は入力メソッドの返事を待ってから insertNewline: になり、
    /// そのときの NSApp.currentEvent がこの keyDown とは限らない（Shift を離したイベントなどに変わる）ので、受けた時点の修飾を覚えておく
    private(set) var returnKeyHasShift = false

    override func keyDown(with event: NSEvent) {
        closeCommentPopover()
        if event.keyCode == 36 || event.keyCode == 76 { returnKeyHasShift = event.modifierFlags.contains(.shift) }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        closeCommentPopover()
        super.scrollWheel(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        closeCommentPopover()
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
        updateCommentPopover(at: point)
        if blockDrag.isOnHandle(point) {
            NSCursor.openHand.set()
        } else if columnEdge(at: point) != nil {
            NSCursor.resizeLeftRight.set()
        } else if checkbox(at: point) != nil || link(at: point) != nil || embed(at: point) != nil || foldButton(at: point) != nil {
            NSCursor.pointingHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideAddRowButton()
        blockDrag.hideHandle()
        closeCommentPopover()
    }

    override func mouseDown(with event: NSEvent) {
        closeCommentPopover()
        let point = convert(event.locationInWindow, from: nil)
        if let (range, state) = checkbox(at: point) {
            // カーソルを動かさずにチェックを切り替える。進行中の `[-]` は完了にする
            let done = state == .done
            replace(NSRange(location: range.location + 1, length: 1), with: done ? " " : "x",
                    actionName: done ? "チェックを外す" : "チェック")
            return
        }
        if let link = link(at: point) {
            onOpenLink?(link, event.modifierFlags.contains(.command))
            return
        }
        if let header = foldButton(at: point) {
            // カーソルは動かさずに開閉する（super に渡すと、隠した行は高さがないのでカーソルが見出し行に入る）
            onToggleFold?(header)
            return
        }
        if let (card, location) = embed(at: point) {
            // ⌥クリックはブロックにカーソルを入れてソースを編集する
            if event.modifierFlags.contains(.option) {
                setSelectedRange(NSRange(location: location, length: 0))
            } else {
                onOpenLink?(.url(card.url), event.modifierFlags.contains(.command))
            }
            return
        }
        guard let hit = columnEdge(at: point) else {
            enterTableCell(at: point)
            return super.mouseDown(with: event)
        }
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
        let width = max(drag.layout.minimumWidth(of: drag.column), TableLayout.snapped(drag.startWidth + (x - drag.startX) / drag.scale))
        guard width != drag.layout.columnWidths[drag.column] else { return }
        drag.layout.columnWidths[drag.column] = width
        onColumnDrag?()
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

    // MARK: - 入力カーソル

    /// macOS 14 からの入力カーソル。NSTextView は行の高さいっぱいに置くので、
    /// 最小行高で広げた行（コールアウト・表・チェックリスト）では文字より長く、上下にはみ出す。
    /// drawInsertionPoint(in:color:turnedOn:) は呼ばれないので、置かれた枠を文字のフォントの高さに縮め直す
    private var insertionIndicator: NSTextInsertionIndicator?
    /// 直近に縮め直した枠。自分で動かしたときの通知を見分けるのに使う
    private var fittedIndicatorFrame: NSRect?

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard let indicator = subview as? NSTextInsertionIndicator, indicator !== insertionIndicator else { return }
        if let insertionIndicator {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: insertionIndicator)
        }
        insertionIndicator = indicator
        indicator.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(insertionIndicatorFrameDidChange),
                                               name: NSView.frameDidChangeNotification, object: indicator)
        fitInsertionIndicator()
    }

    @objc private func insertionIndicatorFrameDidChange(_ notification: Notification) {
        fitInsertionIndicator()
    }

    private func fitInsertionIndicator() {
        guard let indicator = insertionIndicator, indicator.frame != fittedIndicatorFrame,
              let fitted = fittedInsertionRect(for: indicator.frame), fitted != indicator.frame
        else { return }
        fittedIndicatorFrame = fitted
        indicator.frame = fitted
    }

    /// 行の高さいっぱいのカーソルの枠 `rect` を、その位置の文字のフォントの ascender〜descender に縮める。
    /// 文字は直前の文字（入力した文字が引き継ぐ属性）を優先し、記号を隠した位置（0.01pt のフォント）では同じ行の近くの見える文字を使う
    private func fittedInsertionRect(for rect: NSRect) -> NSRect? {
        let selection = selectedRange()
        guard rect.height > 0, selection.length == 0 || hasMarkedText(),
              let layoutManager = textLayoutManager, let content = layoutManager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: selection.location),
              let fragment = layoutManager.textLayoutFragment(for: location)
        else { return nil }
        let frame = fragment.layoutFragmentFrame
        let y = rect.midY - textContainerOrigin.y - frame.minY
        // 折り返しの境目では同じ位置が2つの行にあるので、NSTextView が置いた高さの行を選ぶ
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.minY <= y && y < $0.typographicBounds.maxY })
        else { return nil }
        let string = line.attributedString
        let range = line.characterRange
        let index = content.offset(from: fragment.rangeInElement.location, to: location)
        func visibleFont(at i: Int) -> (NSFont, CGFloat)? {
            guard i >= range.location, i < NSMaxRange(range), i < string.length,
                  let font = string.attribute(.font, at: i, effectiveRange: nil) as? NSFont, font.pointSize >= 1
            else { return nil }
            return (font, string.attribute(.baselineOffset, at: i, effectiveRange: nil) as? CGFloat ?? 0)
        }
        var found: (NSFont, CGFloat)?
        for distance in 0..<max(range.length, 1) {
            found = visibleFont(at: index - 1 - distance) ?? visibleFont(at: index + distance)
            if found != nil { break }
        }
        guard let (font, baselineOffset) = found else { return nil }
        let baseline = textContainerOrigin.y + frame.minY + line.typographicBounds.minY + line.glyphOrigin.y - baselineOffset
        // NSTextView が置いた枠からははみ出さない
        let top = max(rect.minY, baseline - font.ascender)
        let bottom = min(rect.maxY, baseline - font.descender)
        guard bottom > top else { return nil }
        return NSRect(x: rect.minX, y: top, width: rect.width, height: bottom - top)
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

    /// カーソルのある表の行で、ほかのセルをクリックしたら、先にカーソルをそのセルへ移す。
    /// ほかのセルの元の文字は幅ゼロで隠しているので、そのままではクリックした位置の文字を当てられない。
    /// セルを移すと装飾がかけ直され、続く super の mouseDown はそのセルの文字の上で位置を決める
    private func enterTableCell(at point: NSPoint) {
        let location = containerPoint(point)
        guard let fragment = fragment(at: location),
              let row = fragment.decoration as? TableRowDecoration, let live = row.liveColumn,
              let edges = fragment.columnEdges()?.edges,
              let column = edges.firstIndex(where: { location.x < $0 }), column != live,
              let content = textLayoutManager?.textContentManager
        else { return }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let paragraph = NSRange(location: start, length: content.offset(from: fragment.rangeInElement.location,
                                                                        to: fragment.rangeInElement.endLocation))
        guard let cells = row.layout.rows.first(where: { $0.first.map { NSLocationInRange($0.location, paragraph) } == true }),
              column < cells.count
        else { return }
        let string = self.string as NSString
        let cell = cells[column]
        var end = NSMaxRange(cell)
        while end > cell.location, [0x20, 0x09].contains(string.character(at: end - 1)) { end -= 1 }
        setSelectedRange(NSRange(location: end == cell.location ? cell.location + min(1, cell.length) : end, length: 0))
        // 装飾をかけ直した行をレイアウトし直してから、super にクリックの位置を求めさせる
        if let from = content.location(content.documentRange.location, offsetBy: paragraph.location),
           let to = content.location(from, offsetBy: paragraph.length),
           let range = NSTextRange(location: from, end: to) {
            textLayoutManager?.ensureLayout(for: range)
        }
    }

    /// マウス位置にチェックボックスがあれば、`[ ]` の文書内の範囲とチェック状態を返す
    private func checkbox(at point: NSPoint) -> (range: NSRange, state: CheckboxState)? {
        let location = containerPoint(point)
        guard let fragment = fragment(at: location),
              let content = textLayoutManager?.textContentManager
        else { return nil }
        let local = CGPoint(x: location.x - fragment.layoutFragmentFrame.minX, y: location.y - fragment.layoutFragmentFrame.minY)
        guard let hit = fragment.checkboxes().first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(local) }) else { return nil }
        let paragraphStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return (NSRange(location: paragraphStart + hit.range.location, length: hit.range.length), hit.state)
    }

    /// マウス位置が折りたためるコールアウトの開閉の印の上なら、見出し行の先頭の位置を返す。
    /// カーソルがコールアウトの中にあるあいだは、たたまずに開いたままにしているので押せない
    private func foldButton(at point: NSPoint) -> Int? {
        let location = containerPoint(point)
        guard let fragment = fragment(at: location),
              fragment.foldButtonRect()?.offsetBy(dx: 0, dy: fragment.layoutFragmentFrame.minY).contains(location) == true,
              let content = textLayoutManager?.textContentManager
        else { return nil }
        let header = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        // トグルは見出し行や中身にカーソルがあっても開閉できる
        guard let box = fragment.decoration as? BoxDecoration else { return header }
        let string = self.string as NSString
        var end = header
        while end < string.length, string.character(at: end) == 0x3E {
            end = NSMaxRange(string.lineRange(for: NSRange(location: end, length: 0)))
        }
        let selection = selectedRange()
        let caret = min(selection.location, string.length)
        let caretLines = string.lineRange(for: NSRange(location: caret, length: min(selection.length, string.length - caret)))
        guard box.collapsed || NSIntersectionRange(caretLines, NSRange(location: header, length: end - header)).length == 0 else { return nil }
        return header
    }

    /// マウス位置に Link Embed のカードがあれば、カードとブロックの先頭の文書内の位置を返す
    private func embed(at point: NSPoint) -> (card: EmbedCard, location: Int)? {
        let location = containerPoint(point)
        guard let fragment = fragment(at: location), let card = fragment.decoration as? EmbedCard,
              fragment.embedCardRect().offsetBy(dx: 0, dy: fragment.layoutFragmentFrame.minY).contains(location),
              let content = textLayoutManager?.textContentManager
        else { return nil }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return (card, start)
    }

    /// マウス位置の文字にリンクがあれば返す。カーソルがリンクの中にあるあいだは編集中とみなし、クリックでは開かない
    private func link(at point: NSPoint) -> LinkTarget? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        // 挿入位置は文字の境目なので、左右どちらの文字の上にあるかは矩形で確かめる
        for candidate in [index, index - 1] where 0 <= candidate && candidate < storage.length {
            var range = NSRange()
            let target: LinkTarget
            if let name = storage.attribute(.maWikiLink, at: candidate, effectiveRange: &range) as? String {
                target = .note(name)
            } else if let url = storage.attribute(.maURL, at: candidate, effectiveRange: &range) as? String {
                target = .url(url)
            } else {
                continue
            }
            let selection = selectedRange()
            if range.location <= selection.location && NSMaxRange(selection) <= NSMaxRange(range) { return nil }
            if segmentRects(for: range).contains(where: { $0.contains(point) }) { return target }
        }
        return nil
    }

    /// マウス位置の文字に AI へのコメントがあれば、コメントと付けた文字の範囲、マウスの下の矩形を返す。
    /// カーソル行では Styler が属性を付けないので見つからない
    private func aiComment(at point: NSPoint) -> (comment: String, range: NSRange, rect: CGRect)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] where 0 <= candidate && candidate < storage.length {
            var range = NSRange()
            guard let comment = storage.attribute(.maAIComment, at: candidate, effectiveRange: &range) as? String,
                  let rect = segmentRects(for: range).first(where: { $0.contains(point) })
            else { continue }
            return (comment, range, rect)
        }
        return nil
    }

    /// 文書内の範囲が描かれている矩形（ビューの座標）
    private func segmentRects(for range: NSRange) -> [CGRect] {
        guard let layoutManager = textLayoutManager, let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end)
        else { return [] }
        var rects: [CGRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rects.append(frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            return true
        }
        return rects
    }

    // MARK: - AI へのコメントの吹き出し

    /// AI へのコメントを付けた文字の上にマウスがあるあいだ、コメントを吹き出しで出す
    private func updateCommentPopover(at point: NSPoint) {
        guard columnDrag == nil, window?.isKeyWindow == true, let hit = aiComment(at: point) else { return closeCommentPopover() }
        commentPopover.show(hit.comment, for: hit.range, relativeTo: hit.rect, of: self)
    }

    /// 入力・スクロール・クリック・ウインドウの切り替えなどで、吹き出しが残らないように閉じる
    @objc func closeCommentPopover() {
        commentPopover.close()
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

/// 1つのタブの中身。タブごとに作るので、取り消し履歴・カーソル・スクロール位置はタブごとに残る
final class EditorViewController: NSViewController, NSTextViewDelegate {
    var onChange: ((URL, String) -> Void)?
    /// vault のプロパティの型（`.obsidian/types.json`）
    var propertyTypes: () -> PropertyTypes? = { nil }
    /// ノートが対象の `.base` に書かれた `ma:` の型
    var propertySchemas: (_ url: URL, _ text: String) -> [String: PropertySchema] = { _, _ in [:] }
    private(set) var url: URL?
    var onOpenLink: ((LinkTarget, _ newTab: Bool) -> Void)? {
        get { textView.onOpenLink }
        set { textView.onOpenLink = newValue }
    }

    private let textView = EditorTextView(usingTextLayoutManager: true)
    private let placeholder = NSTextField(labelWithString: "ノートを選択してください")
    private let styler = MarkdownStyler()
    private let layoutDelegate = BlockLayoutDelegate()
    private let lineBreakDelegate = TableLineBreakDelegate()
    private var activeLines = NSRange(location: NSNotFound, length: 0)
    /// カーソルのある表のセル（縦棒の間の範囲）。同じ行でもセルが変わったら装飾をかけ直す
    private var activeCell: NSRange?
    /// 直近の装飾で見つかった表。表の中での Tab や Enter の移動先を求めるのに使う
    private var tables: [TableLayout] = []
    /// 直近の装飾で読んだフロントマター。ソース表示のときは nil
    private var frontmatter: Frontmatter?
    /// `schemas` を求めたときのプロパティ。プロパティが変わると対象の `.base` も変わりうるので求め直す
    private var schemaEntries: [FrontmatterEntry]?
    private var schemas: [String: PropertySchema] = [:]
    /// プロパティ欄からの書き換えのあいだだけ、フロントマターの編集を許す
    private var editingProperties = false
    /// 最後に保存へ回した本文。取り消し・やり直しで変わったかどうかの判定に使う
    private var reportedText = ""
    /// `/` の入力補助の一覧
    private let slashMenu = SlashMenu()
    /// 一覧を出している `/` の位置
    private var slashLocation: Int?
    /// 直前の編集で打った `/` の位置。textDidChange で一覧を出すか決める
    private var typedSlash: Int?
    /// 開閉の印で、ファイルの `-`/`+` と逆の状態にしたコールアウトの見出し行の先頭。
    /// `[!note]-` はカーソルが外にあってもたたまず、トグルは `-` なら開き、`+` ならたたむ。ファイルは書き換えない
    private var flippedCallouts: Set<Int> = []
    /// 直近の装飾でたたんで見せたトグル。隠した中身の行にはカーソルを入れない
    private var collapsedToggles: [ToggleBlock] = []

    /// ソース表示（装飾なし）かどうか。切り替えと記録は EditorAreaViewController が受け持つ
    var sourceMode = false {
        didSet { if sourceMode != oldValue, isViewLoaded { restyle(force: true) } }
    }

    /// コールアウトのタイトルの左にアイコンを描くかどうか。切り替えと記録は EditorAreaViewController が受け持つ
    var showsCalloutIcons = true {
        didSet { if showsCalloutIcons != oldValue, isViewLoaded { restyle(force: true) } }
    }

    override func loadView() {
        textView.delegate = self
        textView.textLayoutManager?.delegate = layoutDelegate
        textView.textContentStorage?.delegate = lineBreakDelegate
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
        textView.onColumnDrag = { [weak self] in self?.restyle(force: true) }
        textView.onToggleFold = { [weak self] header in self?.toggleFold(at: header) }
        setUpProperties()
        slashMenu.onChoose = { [weak self] command in self?.applySlashCommand(command) }
        // 取り消し・やり直しでは textDidChange が呼ばれないことがあるので、ここでも保存と装飾をやり直す。
        // 取り消し履歴はウインドウで共有しているので、ほかのタブの取り消しでも呼ばれる（本文が変わったときだけ扱う）
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(textDidChangeByUndo), name: name, object: nil)
        }

        let scrollView = NSScrollView()
        // タブバーの下に置くので、タイトルバーの分の余白は要らない
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        // スクロールやウインドウの切り替えで一覧がカーソルから離れるので閉じる
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(closeSlashMenu),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(closeSlashMenu),
                                               name: NSWindow.didResignKeyNotification, object: nil)
        // AI へのコメントの吹き出しも、スクロールやウインドウの切り替えで文字から離れるので閉じる
        NotificationCenter.default.addObserver(textView, selector: #selector(EditorTextView.closeCommentPopover),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(textView, selector: #selector(EditorTextView.closeCommentPopover),
                                               name: NSWindow.didResignKeyNotification, object: nil)

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
        if let document, document.isReload, document.url == url {
            reload(document.text)
            return
        }
        closeSlashMenu()
        url = document?.url
        placeholder.isHidden = document != nil
        textView.isEditable = document != nil
        textView.string = document?.text ?? ""
        reportedText = textView.string
        schemaEntries = nil
        flippedCallouts = []
        textView.undoManager?.removeAllActions()
        let length = (textView.string as NSString).length
        if let state = document?.viewState {
            let location = min(state.selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(state.selection.length, length - location)))
            restyle(force: true)
            // 差し替えた直後はテキストビューの高さが前のノートのままなので、高さが決まってから動かす
            textView.scrollToBeginningOfDocument(nil)
            let url = url
            DispatchQueue.main.async { [weak self] in
                guard let self, self.url == url else { return }
                scroll(toCharacter: min(state.topCharacter, length))
            }
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            restyle(force: true)
            textView.scrollToBeginningOfDocument(nil)
        }
        focus()
    }

    /// 外部で書き換えられた本文に差し替える。前後の一致する部分を残して違う部分だけを置き換えるので、
    /// 変わっていない段落のレイアウトとスクロール位置はそのまま残る。カーソルは置き換えた範囲の後ろなら文字数の増減だけずらす。
    /// 取り消しの履歴は位置が合わなくなるので捨てる。フォーカスは動かさない
    private func reload(_ text: String) {
        guard let storage = textView.textStorage else { return }
        let old = textView.string as NSString
        let new = text as NSString
        var prefix = 0
        let shorter = min(old.length, new.length)
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        guard range.length > 0 || !replacement.isEmpty else { return }
        let delta = (replacement as NSString).length - range.length
        func moved(_ location: Int) -> Int {
            if location <= range.location { return location }
            if location >= NSMaxRange(range) { return location + delta }
            return range.location + min(location - range.location, (replacement as NSString).length)
        }
        let selection = textView.selectedRange()
        let start = moved(selection.location)
        let end = moved(NSMaxRange(selection))
        // 画面より上が書き換わったら、上端に見えていた行が同じ高さに残るようにスクロールをずらす
        let topCharacter = topVisibleCharacter()
        var anchor: CGFloat?
        if range.location < topCharacter {
            ensureLayout(through: topCharacter + 1000)
            anchor = top(ofCharacter: topCharacter)
        }

        closeSlashMenu()
        shiftFlippedCallouts(replacing: range, with: replacement)
        storage.replaceCharacters(in: range, with: replacement)
        textView.textDidReload()
        reportedText = textView.string
        schemaEntries = nil
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: start, length: max(end - start, 0)))
        restyle(force: true)
        if anchor != nil { ensureLayout(through: moved(topCharacter) + 1000) }
        if let anchor, let shifted = top(ofCharacter: moved(topCharacter)), shifted != anchor {
            textView.scroll(NSPoint(x: 0, y: textView.visibleRect.minY + shifted - anchor))
        }
    }

    /// 日本語の変換中（未確定の文字がある）か
    var isComposing: Bool { textView.hasMarkedText() }

    /// 戻る・進むで戻ってきたときに復元するための、カーソルと画面の上端の位置
    var viewState: NoteViewState? {
        guard url != nil else { return nil }
        return NoteViewState(selection: textView.selectedRange(), topCharacter: topVisibleCharacter())
    }

    /// 画面の上端にある行の先頭の文字の位置
    private func topVisibleCharacter() -> Int {
        guard let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager else { return 0 }
        let y = textView.visibleRect.minY - textView.textContainerOrigin.y
        guard y > 0, let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return 0 }
        let start = fragment.rangeInElement.location
        let line = fragment.textLineFragments.first { fragment.layoutFragmentFrame.minY + $0.typographicBounds.maxY > y }
        let location = line.flatMap { content.location(start, offsetBy: $0.characterRange.location) } ?? start
        return content.offset(from: content.documentRange.location, to: location)
    }

    /// その文字の行が画面の上端に来るようにスクロールする。TextKit 2 は画面外の高さを見積もりで持つので、手前までレイアウトしてから位置を求める
    private func scroll(toCharacter index: Int) {
        guard let top = top(ofCharacter: index) else { return textView.scrollToBeginningOfDocument(nil) }
        // 最初の行なら上端の余白も見せる
        textView.scroll(NSPoint(x: 0, y: top <= 0 ? 0 : top + textView.textContainerOrigin.y))
    }

    /// 先頭からその文字までをレイアウトする。書き換えた段落は、測る位置より後ろまで含めてレイアウトし直さないと古い高さのままだった
    private func ensureLayout(through index: Int) {
        guard let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager,
              let end = content.location(content.documentRange.location, offsetBy: min(index, (textView.string as NSString).length)),
              let range = NSTextRange(location: content.documentRange.location, end: end)
        else { return }
        layoutManager.ensureLayout(for: range)
    }

    /// その文字の行の上端（テキストコンテナの座標）。TextKit 2 は画面外の高さを見積もりで持つので、手前までレイアウトしてから求める
    private func top(ofCharacter index: Int) -> CGFloat? {
        guard let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: index),
              let range = NSTextRange(location: content.documentRange.location, end: location)
        else { return nil }
        layoutManager.ensureLayout(for: range)
        var top: CGFloat?
        layoutManager.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: []) { _, frame, _, _ in
            top = frame.minY
            return false
        }
        return top
    }

    func focus() {
        if url != nil { view.window?.makeFirstResponder(textView) }
    }

    /// 選択中の文字に AI 向けのコメントを付ける。`==選択した文字==<!-- AI: コメント -->` と書き、
    /// Obsidian でもハイライトとして読める形にする。記法が行をまたげないので、1行の中の選択に限る
    func addAIComment() {
        guard url != nil, let range = textView.commentableSelection else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "コメントを追加"
        alert.informativeText = "選んだ箇所について、このノートを読む AI への指示や補足を入力してください。"
        alert.addButton(withTitle: "追加")
        alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "例: ここを短く書き直して"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let comment = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // コメントを途中で閉じてしまう `-->` だけを崩す（他の `--` は書いたまま残す）
            .replacingOccurrences(of: "-->", with: "->")
        guard !comment.isEmpty else { return }
        let selected = (textView.string as NSString).substring(with: range)
        let replacement = "==\(selected)==<!-- AI: \(comment) -->"
        textView.replace(range, with: replacement, actionName: "コメントを追加")
        textView.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
    }

    func textDidChange(_ notification: Notification) {
        // 日本語の変換中（未確定文字あり）は保存も装飾もしない。確定時にもう一度呼ばれる
        guard !textView.hasMarkedText() else { return }
        reportedText = textView.string
        if let url { onChange?(url, textView.string) }
        restyle(force: true)
        updateSlashMenu()
    }

    @objc private func textDidChangeByUndo() {
        guard url != nil, textView.string != reportedText else { return }
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        restyle(force: false)
        if let slashLocation, !textView.hasMarkedText() {
            let selection = textView.selectedRange()
            if selection.length > 0 || selection.location <= slashLocation { closeSlashMenu() }
        }
    }

    // MARK: - スラッシュの入力補助

    /// `/` を打った直後に一覧を出し、続けて打った文字で絞り込む。空白を打つか、当てはまる項目がなくなったら閉じる
    private func updateSlashMenu() {
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        if let typed = typedSlash {
            typedSlash = nil
            // 行頭か空白の直後の `/` だけ。表の中と、隠したフロントマターの中では出さない
            let afterSpace = typed == 0 || [0x20, 0x09, 0x0A, 0x0D, 0x3000].contains(string.character(at: typed - 1))
            if afterSpace, typed < string.length, string.character(at: typed) == 0x2F, selection == NSRange(location: typed + 1, length: 0),
               !tables.contains(where: { NSLocationInRange(typed, $0.tableRange) }),
               frontmatter.map({ typed >= NSMaxRange($0.range) }) ?? true {
                slashLocation = typed
            }
        }
        guard let slash = slashLocation else { return }
        guard selection.length == 0, selection.location > slash, slash < string.length, string.character(at: slash) == 0x2F else {
            return closeSlashMenu()
        }
        let query = string.substring(with: NSRange(location: slash + 1, length: selection.location - slash - 1))
        let commands = SlashCommand.matching(query)
        guard query.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !commands.isEmpty, let window = view.window else {
            return closeSlashMenu()
        }
        let anchor = textView.firstRect(forCharacterRange: NSRange(location: slash, length: 1), actualRange: nil)
        slashMenu.show(commands, below: anchor, in: window)
    }

    @objc private func closeSlashMenu() {
        slashLocation = nil
        slashMenu.hide()
    }

    private func applySlashCommand(_ command: SlashCommand) {
        guard let slash = slashLocation else { return }
        let caret = textView.selectedRange().location
        closeSlashMenu()
        let edit = command.edit(in: textView.string as NSString, slash: slash, caret: caret)
        textView.replace(edit.range, with: edit.replacement, actionName: command.title)
        textView.setSelectedRange(edit.selection)
    }

    /// 一覧を出しているあいだの ↑↓・Enter・Tab・Esc
    private func handleSlashMenuCommand(_ selector: Selector) -> Bool {
        guard slashMenu.isVisible, !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            slashMenu.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            slashMenu.moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            if let command = slashMenu.selectedCommand { applySlashCommand(command) }
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
            closeSlashMenu()
        default:
            return false
        }
        return true
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
        let cell = tables.lazy.compactMap { table in
            table.cell(containing: location).map { table.rows[$0.row][$0.column] }
        }.first
        guard force || lines != activeLines || cell != activeCell else { return }
        activeLines = lines
        activeCell = cell
        frontmatter = sourceMode ? nil : Frontmatter.parse(storage.string)
        let properties = textView.propertiesView
        if let frontmatter {
            if let url, schemaEntries.map({ $0.map(\.key) != frontmatter.entries.map(\.key) || $0.map(\.value) != frontmatter.entries.map(\.value) }) ?? true {
                schemas = propertySchemas(url, storage.string)
                schemaEntries = frontmatter.entries
            }
            properties.update(entries: frontmatter.entries, types: propertyTypes(), schemas: schemas)
        }
        let height = frontmatter.map { _ in properties.height }
        // 文書全体に属性をかけ直すと、TextKit 2 がすべての段落のレイアウトを捨てて高さを見積もり直す。
        // スクロール位置に見える中身がずれたり白くなったりするので、写しに装飾してから変わった段落だけ書き戻す
        let styled = NSTextStorage(attributedString: storage)
        tables = styler.apply(to: styled, activeRange: lines, availableWidth: textView.textWidth, sourceMode: sourceMode,
                              selection: selection,
                              draggedWidths: textView.draggedWidths,
                              frontmatter: frontmatter.flatMap { fm in height.map { (fm.range, $0) } },
                              calloutIcons: showsCalloutIcons, flippedCallouts: flippedCallouts)
        let string = storage.string as NSString
        storage.beginEditing()
        var position = 0
        while position < length {
            let paragraph = string.paragraphRange(for: NSRange(location: position, length: 0))
            position = NSMaxRange(paragraph)
            guard !storage.attributedSubstring(from: paragraph).isEqual(to: styled.attributedSubstring(from: paragraph)) else { continue }
            styled.enumerateAttributes(in: paragraph) { attributes, range, _ in storage.setAttributes(attributes, range: range) }
        }
        storage.endEditing()
        textView.typingAttributes = styler.baseAttributes
        textView.placeProperties(height: height)
        collapsedToggles = sourceMode ? [] : ToggleBlock.find(in: storage.string).filter { toggle in
            guard let content = toggle.content else { return false }
            return toggle.isCollapsed(flipped: flippedCallouts.contains(toggle.header)) && NSIntersectionRange(content, lines).length == 0
        }
    }

    // MARK: - コールアウトとトグルの開閉

    /// 開閉の印を押したとき。トグルをたたむときにカーソルが中身の行にあれば、見出し行の末尾へ出す（中身にカーソルがあると開いたままになる）
    private func toggleFold(at header: Int) {
        if flippedCallouts.remove(header) == nil { flippedCallouts.insert(header) }
        if let toggle = ToggleBlock.find(in: textView.string).first(where: { $0.header == header }),
           let content = toggle.content, toggle.isCollapsed(flipped: flippedCallouts.contains(header)),
           NSIntersectionRange(activeLines, content).length > 0 {
            textView.setSelectedRange(NSRange(location: toggle.headerEnd, length: 0))
        }
        restyle(force: true)
    }

    /// たたんだトグルの隠した行と隣の行を消去でつなげると、つないだ文字が隠れてしまうので、先に開く
    private func unfoldToggleBeforeJoining(_ selector: Selector) {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return }
        let joined: ToggleBlock?
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)):
            joined = collapsedToggles.first { $0.content.map { NSMaxRange($0) + 1 } == selection.location }
        case #selector(NSResponder.deleteForward(_:)):
            joined = collapsedToggles.first { $0.headerEnd == selection.location }
        default:
            joined = nil
        }
        guard let joined else { return }
        if flippedCallouts.remove(joined.header) == nil { flippedCallouts.insert(joined.header) }
        restyle(force: true)
    }

    // MARK: - プロパティ

    private func setUpProperties() {
        let properties = textView.propertiesView
        properties.onSet = { [weak self] key, value, type in
            self?.editFrontmatter("プロパティの変更") { $0.setting(key, to: value, type: type) }
        }
        properties.onAdd = { [weak self] key in
            guard let self else { return }
            let type = propertyTypes()?.type(of: key) ?? .text
            editFrontmatter("プロパティの追加") { $0.setting(key, to: type.isList ? .list([]) : .scalar(""), type: type) }
        }
        properties.onCancelAdd = { [weak self] in
            // プロパティを足すために作った空のフロントマターは消す
            guard let self, let frontmatter, frontmatter.entries.isEmpty,
                  (textView.string as NSString).substring(with: frontmatter.range) == Frontmatter.emptyBlock
            else { return }
            editFrontmatter("プロパティの追加") { Frontmatter.Edit(range: $0.range, replacement: "") }
        }
        properties.onRemove = { [weak self] key in
            self?.editFrontmatter("プロパティの削除") { $0.removing(key) }
        }
        properties.onRename = { [weak self] key, newKey in
            guard let self else { return }
            if let types = propertyTypes(), let entry = frontmatter?.entry(key) {
                types.set(types.type(of: key, value: entry.value), for: newKey)
            }
            let text = textView.string
            editFrontmatter("プロパティ名の変更") { $0.renaming(key, to: newKey, in: text) }
        }
        properties.onChangeType = { [weak self] key, type in
            guard let self, let entry = frontmatter?.entry(key) else { return }
            propertyTypes()?.set(type, for: key)
            // リストと1つの値のあいだで変えたときは、値の形も合わせる
            let value: PropertyValue
            switch (entry.value, type.isList) {
            case (.scalar(let text), true): value = .list(text.isEmpty ? [] : [text])
            case (.list(let items), false): value = .scalar(items.joined(separator: ", "))
            default: value = entry.value
            }
            if value == entry.value {
                restyle(force: true)
            } else {
                editFrontmatter("プロパティの型の変更") { $0.setting(key, to: value, type: type) }
            }
        }
        properties.onHeightChange = { [weak self] in self?.restyle(force: true) }
    }

    /// `.base` が増えたり変わったりしたとき（起動直後のツリーの読み込みも含む）に、型を求め直す
    func refreshSchemas() {
        schemaEntries = nil
        restyle(force: true)
    }

    /// `.base` の表から値を変えたとき。エディタの編集として書き換えるので ⌘Z で戻せる
    func setProperty(_ key: String, to value: PropertyValue, type: PropertyType) {
        if Frontmatter.parse(textView.string) == nil {
            editingProperties = true
            textView.replace(NSRange(location: 0, length: 0), with: Frontmatter.emptyBlock, actionName: "プロパティの変更")
            editingProperties = false
        }
        editFrontmatter("プロパティの変更") { $0.setting(key, to: value, type: type) }
    }

    /// `.base` の表からプロパティ名を変えたとき。新しい名前のキーがすでにあれば上書きせず false を返す
    func renameProperty(_ key: String, to newKey: String) -> Bool {
        let text = textView.string
        guard let frontmatter = Frontmatter.parse(text), frontmatter.entry(key) != nil, frontmatter.entry(newKey) == nil else { return false }
        editFrontmatter("プロパティ名の変更") { $0.renaming(key, to: newKey, in: text) }
        return true
    }

    /// ⌘; でプロパティを足す。フロントマターがなければ先頭に作る
    func addProperty() {
        guard url != nil else { return }
        if sourceMode {
            NSSound.beep()
            return
        }
        if Frontmatter.parse(textView.string) == nil {
            editingProperties = true
            textView.replace(NSRange(location: 0, length: 0), with: Frontmatter.emptyBlock, actionName: "プロパティの追加")
            editingProperties = false
        }
        textView.propertiesView.beginAdding()
    }

    private func editFrontmatter(_ actionName: String, _ makeEdit: (Frontmatter) -> Frontmatter.Edit?) {
        guard let frontmatter = Frontmatter.parse(textView.string), let edit = makeEdit(frontmatter) else { return }
        editingProperties = true
        textView.replace(edit.range, with: edit.replacement, actionName: actionName)
        editingProperties = false
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if replacementString == "/", range.length == 0, !textView.hasMarkedText() { typedSlash = range.location }
        let allowed = shouldAllowChange(in: range)
        if allowed { shiftFlippedCallouts(replacing: range, with: replacementString) }
        return allowed
    }

    /// 開閉の印で開いたコールアウトの位置を、書き換えで増減した文字数に合わせて動かす。書き換える範囲の中の見出しは忘れる
    private func shiftFlippedCallouts(replacing range: NSRange, with replacement: String?) {
        guard !flippedCallouts.isEmpty else { return }
        let delta = ((replacement ?? "") as NSString).length - range.length
        flippedCallouts = Set(flippedCallouts.compactMap { header in
            if header < range.location { return header }
            if header >= NSMaxRange(range) { return header + delta }
            return nil
        })
    }

    /// 隠したフロントマターを本文の編集で壊さないよう、一部だけにかかる書き換えは止める（全体を消すのは許す）
    private func shouldAllowChange(in range: NSRange) -> Bool {
        // 取り消し・やり直しも止めない（止めると文字は戻るのに textDidChange が呼ばれず、保存されない）
        let undoManager = textView.undoManager
        guard !editingProperties, undoManager?.isUndoing != true, undoManager?.isRedoing != true,
              let frontmatter else { return true }
        let overlap = NSIntersectionRange(range, frontmatter.range)
        let touches = overlap.length > 0 || (range.length == 0 && range.location < NSMaxRange(frontmatter.range))
        return !touches || NSEqualRanges(overlap, frontmatter.range)
    }

    // MARK: - 表の中のキー操作

    /// Tab で次のセル、Shift+Tab で前のセル、Enter で下の行、Shift+Enter でセル内の改行（<br>）
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if handleSlashMenuCommand(selector) { return true }
        if !sourceMode { unfoldToggleBeforeJoining(selector) }
        if !sourceMode, selector == #selector(NSResponder.insertTab(_:))
            || selector == #selector(NSResponder.insertBacktab(_:)),
           shiftListItems(outdent: selector == #selector(NSResponder.insertBacktab(_:))) {
            return true
        }
        guard !sourceMode, textView.selectedRange().length == 0 else { return false }
        let caret = textView.selectedRange().location
        guard let table = tables.first(where: { NSLocationInRange(caret, $0.tableRange) || caret == $0.endOfLastRow }),
              let (row, column) = table.cell(containing: caret)
        else {
            return breakCalloutLine(selector, at: caret) || breakListLine(selector, at: caret) || continueList(selector, at: caret)
                || continueToggle(selector, at: caret)
        }
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
        case #selector(NSResponder.insertNewline(_:)) where self.textView.returnKeyHasShift,
             #selector(NSResponder.insertLineBreak(_:)):
            self.textView.replace(NSRange(location: caret, length: 0), with: "<br>", actionName: "セル内の改行")
            // 表示のうえでは改行の直後なので、カーソルは次の行の先頭に出す
            textView.setSelectedRange(NSRange(location: caret + 4, length: 0), affinity: .downstream, stillSelecting: false)
        case #selector(NSResponder.deleteBackward(_:)):
            // <br> の直後で消したらタグごと消す。1文字ずつ消すと、途中まで消えたタグが文字のまま見える
            let cell = table.rows[row][column]
            let start = max(cell.location, caret - 6)
            let string = textView.string as NSString
            let tag = string.range(of: #"<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive],
                                   range: NSRange(location: start, length: caret - start))
            guard tag.location != NSNotFound else { return false }
            self.textView.replace(tag, with: "", actionName: "セル内の改行の削除")
            textView.setSelectedRange(NSRange(location: tag.location, length: 0))
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

    /// コールアウトの中で Shift+Enter を押したら、次の行にも同じ深さの `>` を付けてコールアウトの中で改行する
    private func breakCalloutLine(_ selector: Selector, at caret: Int) -> Bool {
        let shiftReturn = selector == #selector(NSResponder.insertNewline(_:)) && textView.returnKeyHasShift
        guard shiftReturn || selector == #selector(NSResponder.insertLineBreak(_:)),
              let edit = CalloutLineBreak.edit(in: textView.string as NSString, caret: caret)
        else { return false }
        textView.replace(edit.range, with: edit.replacement, actionName: "改行")
        textView.setSelectedRange(NSRange(location: edit.caret, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    /// リスト項目や続きの行で Shift+Enter を押したら、新しい項目を作らずに項目の中で改行する（続きの行を本文の開始位置まで字下げする）
    private func breakListLine(_ selector: Selector, at caret: Int) -> Bool {
        let shiftReturn = selector == #selector(NSResponder.insertNewline(_:)) && textView.returnKeyHasShift
        guard shiftReturn || selector == #selector(NSResponder.insertLineBreak(_:)),
              let edit = ListLineBreak.edit(in: textView.string as NSString, caret: caret)
        else { return false }
        textView.replace(edit.range, with: edit.replacement, actionName: "改行")
        textView.setSelectedRange(NSRange(location: edit.caret, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    /// リスト項目や続きの行で Enter を押したら次の項目を作る（空の項目ならリストを抜ける）。Shift+Enter は breakListLine
    private func continueList(_ selector: Selector, at caret: Int) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)),
              !textView.returnKeyHasShift,
              let edit = ListContinuation.edit(in: textView.string as NSString, caret: caret)
        else { return false }
        textView.replace(edit.range, with: edit.replacement, actionName: "改行")
        textView.setSelectedRange(NSRange(location: edit.caret, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    /// トグルの中で Enter を押したとき。次の行にも同じ深さの `>` を付けてトグルの中に行を作る。
    /// 中身の最後の空の行ではトグルを抜ける。たたんだトグルの見出し行では、中身が空なら開いて中身の行へ、中身があればトグルの後ろに行を作る
    private func continueToggle(_ selector: Selector, at caret: Int) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), !textView.returnKeyHasShift else { return false }
        let string = textView.string as NSString
        // カーソルを含む、いちばん内側のトグル
        guard let toggle = ToggleBlock.find(in: textView.string).last(where: {
            $0.header <= caret && caret <= ($0.content.map(NSMaxRange) ?? $0.headerEnd)
        }) else { return false }
        func insert(_ text: String, at location: Int) {
            textView.replace(NSRange(location: location, length: 0), with: text, actionName: "改行")
            textView.setSelectedRange(NSRange(location: location + (text as NSString).length, length: 0))
        }
        let prefix = toggle.prefix.hasSuffix(" ") || toggle.prefix.hasSuffix("\t") ? toggle.prefix : toggle.prefix + " "
        let lines = toggle.contentLines(in: string)

        if caret <= toggle.headerEnd {
            // タイトルより手前（`> [!toggle]-` の途中）では通常の改行にする
            guard caret >= toggle.titleStart else { return false }
            guard collapsedToggles.contains(toggle), let content = toggle.content else {
                insert("\n" + prefix, at: caret)
                return true
            }
            let isBlank = { (line: NSRange) in
                string.substring(with: line).allSatisfy { $0 == ">" || $0 == " " || $0 == "\t" }
            }
            if lines.allSatisfy(isBlank) {
                // 作ったばかりの空のトグル。開いて中身の最初の行へ（先に開かないと、隠した行に入れずに見出し行へ戻される）
                if flippedCallouts.remove(toggle.header) == nil { flippedCallouts.insert(toggle.header) }
                restyle(force: true)
                textView.setSelectedRange(NSRange(location: NSMaxRange(lines[0]), length: 0))
            } else {
                insert("\n\n", at: NSMaxRange(content))
            }
            textView.scrollRangeToVisible(textView.selectedRange())
            return true
        }

        guard let line = lines.first(where: { $0.location <= caret && caret <= NSMaxRange($0) }) else { return false }
        let text = string.substring(with: line)
        let prefixLength = ToggleBlock.prefixLength(of: text)
        guard caret >= line.location + prefixLength else { return false }
        let depth = ToggleBlock.depth(of: text)
        if depth == toggle.depth, prefixLength == (text as NSString).length, line == lines.last {
            // 中身の最後の空の行ではトグルを抜ける。前の行に続けて読まれないよう、空行を挟む
            let outer = ToggleBlock.prefix(depth: toggle.depth - 1)
            let replacement = outer + "\n" + outer
            textView.replace(line, with: replacement, actionName: "改行")
            textView.setSelectedRange(NSRange(location: line.location + (replacement as NSString).length, length: 0))
        } else {
            var linePrefix = string.substring(with: NSRange(location: line.location, length: prefixLength))
            if !linePrefix.hasSuffix(" ") && !linePrefix.hasSuffix("\t") { linePrefix += " " }
            insert("\n" + linePrefix, at: caret)
        }
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    /// リスト項目の行で Tab なら1段深く、Shift+Tab なら1段浅くする（カーソルの位置によらず、子の項目も一緒に）。
    /// リスト項目の行でなければ false
    private func shiftListItems(outdent: Bool) -> Bool {
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        // 行番号は手前の改行の数。範囲選択が次の行の先頭で終わるときは、その行を含めない
        func line(at location: Int) -> Int {
            string.substring(to: location).utf16.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        }
        let firstLine = line(at: selection.location)
        var end = NSMaxRange(selection)
        if selection.length > 0, string.character(at: end - 1) == 0x0A { end -= 1 }
        let lastLine = max(firstLine, line(at: end))
        let mover = BlockMover(textView.string)
        guard let shift = mover.shiftingListItems(in: firstLine...lastLine, outdent: outdent) else { return false }
        // Tab をリストの行で受けたら、何も変わらない（すでに一番浅い）ときもタブ文字は入れない
        guard shift.shifts.contains(where: { $0 != 0 }) else { return true }

        let start = mover.lines[..<shift.lines.lowerBound].reduce(0) { $0 + ($1 as NSString).length + 1 }
        let length = mover.lines[shift.lines].reduce(0) { $0 + ($1 as NSString).length + 1 } - 1
        // 選択の位置を、行頭で増減した文字数に合わせて動かす（外した空白の中にあった位置は行頭へ）
        var lineStarts: [Int] = []
        var position = start
        for text in mover.lines[shift.lines] {
            lineStarts.append(position)
            position += (text as NSString).length + 1
        }
        func mapped(_ location: Int) -> Int {
            var result = location
            for (lineStart, delta) in zip(lineStarts, shift.shifts) where lineStart <= location {
                result += delta >= 0 ? delta : -min(-delta, location - lineStart)
            }
            return result
        }
        let newStart = mapped(selection.location)
        let newEnd = selection.length == 0 ? newStart : mapped(NSMaxRange(selection))
        textView.replace(NSRange(location: start, length: length), with: shift.text.joined(separator: "\n"),
                         actionName: outdent ? "インデントを減らす" : "インデントを増やす")
        textView.setSelectedRange(NSRange(location: newStart, length: max(0, newEnd - newStart)))
        return true
    }

    /// 区切り行は高さ 0 で隠しているので、カーソルが入りそうになったら上下の行へ飛ばす
    func textView(
        _ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange
    ) -> NSRange {
        // カーソルは隠したフロントマターに入れず、本文の先頭に置く
        if let frontmatter, new.length == 0, new.location < NSMaxRange(frontmatter.range) {
            return NSRange(location: NSMaxRange(frontmatter.range), length: 0)
        }
        // たたんだトグルの中身の行にはカーソルを入れず、下へ動くときはトグルの次の行の先頭、上へ動くときは見出し行の末尾へ飛ばす
        if !sourceMode, new.length == 0,
           let toggle = collapsedToggles.filter({ toggle in
               toggle.content.map { $0.location <= new.location && new.location <= NSMaxRange($0) } ?? false
           }).max(by: { $0.content!.length < $1.content!.length }),
           let content = toggle.content {
            let after = NSMaxRange(content) + 1
            if new.location > old.location, after <= (textView.string as NSString).length {
                return NSRange(location: after, length: 0)
            }
            return NSRange(location: toggle.headerEnd, length: 0)
        }
        // 表のセルの <br> の途中は見えない位置なので、キー操作なら進む向きの端、クリックなら手前の端へ寄せる
        if !sourceMode, new.length == 0, tables.contains(where: { NSLocationInRange(new.location, $0.tableRange) }),
           let tag = lineBreakTag(around: new.location) {
            let forward = NSApp.currentEvent?.type == .keyDown && new.location > old.location
            return NSRange(location: forward ? NSMaxRange(tag) : tag.location, length: 0)
        }
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

    /// `location` が <br> の途中（両端を除く）にあれば、そのタグの範囲
    private func lineBreakTag(around location: Int) -> NSRange? {
        let string = textView.string as NSString
        let start = max(0, location - 5)
        let range = NSRange(location: start, length: min(string.length, location + 5) - start)
        let tag = try? NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])
        return tag?.matches(in: string as String, range: range).map(\.range)
            .first { $0.location < location && location < NSMaxRange($0) }
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
