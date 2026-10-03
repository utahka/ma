import AppKit

/// `.base` のカードのビュー（`type: cards`）。グループごとに見出しを置き、ノートを1枚ずつカードにしてウィンドウの幅に合わせて並べる。
/// カードの上部はノート名と `order` のプロパティ（チップ・日付など）、下部は長い文字列のプロパティ（AI の相談と人間の返事など）の全文。
/// 下部の文字はその場で書き換えられ、別の場所を押すか ⌘Return で確定する（Esc で元に戻す）
final class BaseCardsView: NSScrollView {
    struct Layout {
        /// 上部に並べるプロパティ（ノート名は除く）
        let top: [String]
        /// 下部に全文で出すプロパティ
        let body: [String]
        /// 人間が書き込むプロパティ。これが空で、ほかの `body` に値があるカードを「返事待ち」にする
        let reply: String?
    }

    struct Content {
        let groups: [BaseFile.Group]
        let groupBy: String?
        let collapsed: Set<String>
        let layout: Layout
        let schemas: [String: PropertySchema]
        let types: [String: PropertyType]
        /// 日付の列（値は時刻を含むかどうか）。表と同じ判定
        let dateColumns: [String: Bool]
        let displayName: (String) -> String
    }

    var onOpenNote: ((NoteRecord, _ newTab: Bool) -> Void)?
    /// 値を変えたとき（ノート、キー、値、型）。ノートへの書き込みは呼び出し側が受け持つ
    var onCommit: ((NoteRecord, String, PropertyValue, PropertyType) -> Void)?
    var onToggleGroup: ((BaseValue) -> Void)?

    private var content: Content?
    /// 書いている途中に作り直しを求められたら、確定してから作り直す（書きかけの文字を消さないように）
    private var needsRender = false
    private var columns = 0
    private let document = CardsDocumentView()
    private let stack = NSStackView()

    private static let minimumCardWidth: CGFloat = 340
    private static let maximumColumns = 3
    private static let gap: CGFloat = 14
    private static let inset: CGFloat = 8

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        documentView = document
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ content: Content) {
        self.content = content
        render()
    }

    /// 返事待ちのカードか。返事の欄が空で、ほかの下部のプロパティ（相談など）に値がある
    static func isAwaiting(_ note: NoteRecord, layout: Layout, types: [String: PropertyType]) -> Bool {
        guard let reply = layout.reply else { return false }
        let context = NoteContext(note: note, types: types)
        guard context.value(of: reply).isEmpty else { return false }
        return layout.body.contains { $0 != reply && !context.value(of: $0).isEmpty }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 並べる列の数が変わるときだけ並べ直す
        if content != nil, columnCount() != columns { render() }
    }

    private var isEditing: Bool {
        (window?.firstResponder as? CardTextView)?.isDescendant(of: self) == true
    }

    private func columnCount() -> Int {
        let width = contentSize.width - Self.inset - 20
        return max(1, min(Self.maximumColumns, Int((width + Self.gap) / (Self.minimumCardWidth + Self.gap))))
    }

    private func render() {
        guard !isEditing else {
            needsRender = true
            return
        }
        needsRender = false
        guard let content else { return }
        let origin = contentView.bounds.origin
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        columns = columnCount()
        for group in content.groups {
            if let value = group.value, let groupBy = content.groupBy {
                if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(28, after: last) }
                let header = sectionHeader(value, property: groupBy, notes: group.notes, content: content)
                addFullWidth(header)
                if content.collapsed.contains(value.text) { continue }
            }
            addFullWidth(grid(group.notes.map { card($0, content: content) }))
        }
        layoutSubtreeIfNeeded()
        contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, max(0, document.frame.height - contentView.bounds.height))))
        reflectScrolledClipView(contentView)
    }

    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // MARK: - グループの見出し

    private func sectionHeader(_ value: BaseValue, property: String, notes: [NoteRecord], content: Content) -> NSView {
        let collapsed = content.collapsed.contains(value.text)
        let image = NSImage(systemSymbolName: collapsed ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill", accessibilityDescription: nil) ?? NSImage()
        let disclosure = NSButton(image: image.withSymbolConfiguration(.init(pointSize: 9, weight: .regular)) ?? image, target: nil, action: nil)
        disclosure.isBordered = false
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.setAccessibilityLabel(collapsed ? "グループを開く" : "グループを畳む")
        disclosure.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let title: NSView
        if let schema = content.schemas[property], !value.isEmpty {
            title = Self.chipsView(schema.chips(for: value))
        } else {
            let label = NSTextField(labelWithString: value.isEmpty ? "（なし）" : value.text)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .maText
            title = label
        }
        let count = NSTextField(labelWithString: "\(notes.count)")
        count.font = .systemFont(ofSize: 13)
        count.textColor = .secondaryLabelColor
        var views = [disclosure, title, count]
        let awaiting = notes.filter { Self.isAwaiting($0, layout: content.layout, types: content.types) }.count
        if awaiting > 0 {
            let label = NSTextField(labelWithString: "返事待ち \(awaiting)")
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .systemOrange
            views.append(label)
        }
        let row = NSStackView(views: views)
        row.spacing = 8
        row.setCustomSpacing(6, after: disclosure)
        let header = ClickableView { [weak self] in self?.onToggleGroup?(value) }
        disclosure.target = header
        disclosure.action = #selector(ClickableView.click)
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            row.topAnchor.constraint(equalTo: header.topAnchor),
            row.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
        ])
        return header
    }

    // MARK: - カード

    /// カードを列の数ずつ横に並べる。最後の行は空きを詰め物で埋めて、カードの幅をそろえる
    private func grid(_ cards: [NSView]) -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Self.gap
        for start in stride(from: 0, to: cards.count, by: columns) {
            var items = Array(cards[start..<min(start + columns, cards.count)])
            while items.count < columns { items.append(NSView()) }
            let row = NSStackView(views: items)
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = Self.gap
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        return rows
    }

    private func card(_ note: NoteRecord, content: Content) -> NSView {
        let layout = content.layout
        let context = NoteContext(note: note, types: content.types, schemas: content.schemas)
        let awaiting = Self.isAwaiting(note, layout: layout, types: content.types)
        let card = CardView()
        card.isAwaiting = awaiting

        let title = CardTitle(labelWithString: note.basename)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .maLink
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = note.basename
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.onClick = { [weak self] newTab in self?.onOpenNote?(note, newTab) }
        var titleViews: [NSView] = [title]
        if awaiting {
            let badge = Self.chipsView([ChipsView.Chip(label: "返事待ち", color: .systemOrange)])
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleViews.append(badge)
        }
        let titleRow = NSStackView(views: titleViews)
        titleRow.spacing = 8
        titleRow.alignment = .centerY

        var sections: [NSView] = [titleRow]
        let properties = FlowView()
        for property in layout.top {
            if let item = topItem(property, note: note, context: context, content: content) { properties.addSubview(item) }
        }
        if !properties.subviews.isEmpty { sections.append(properties) }
        for property in layout.body {
            sections.append(bodyItem(property, note: note, context: context, content: content, isReply: property == layout.reply))
        }

        let column = NSStackView(views: sections)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        // 同じ行のカードの高さがそろうときは、余りをカードの下に回す（相談と返事の間を空けない）
        column.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -14).isActive = true
        let fit = column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        fit.priority = .defaultLow - 1
        fit.isActive = true
        for section in sections { section.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return card
    }

    /// 上部のプロパティ。選択肢のあるものはチップ（押すと選ぶ）、日付は押すとカレンダー、ほかは「名前 値」の文字
    private func topItem(_ property: String, note: NoteRecord, context: NoteContext, content: Content) -> NSView? {
        let value = context.value(of: property)
        let key = Self.noteKey(property)
        if let schema = content.schemas[property] {
            let chips = Self.chipsView(schema.chips(for: value))
            if chips.chips.isEmpty {
                // 値がなくても押して選べるように、プロパティ名を薄く出す
                chips.placeholder = content.displayName(property)
                let width = ceil(NSAttributedString(string: chips.placeholder ?? "", attributes: [.font: NSFont.systemFont(ofSize: 13)]).size().width)
                chips.constraints.first { $0.firstAttribute == .width }?.constant = width
            }
            if let key {
                chips.onClick = { [weak self] view in
                    schema.optionsMenu(for: note.properties[key] ?? .scalar("")) { [weak self] value in
                        self?.onCommit?(note, key, value, schema.kind == .multiSelect ? .multitext : .text)
                    }.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 2), in: view)
                }
            }
            chips.toolTip = content.displayName(property)
            return chips
        }
        if let includesTime = content.dateColumns[property], let key {
            let cell = DateCell()
            cell.includesTime = includesTime
            cell.placeholder = content.displayName(property)
            cell.text = value.text
            cell.onChange = { [weak self] text in
                self?.onCommit?(note, key, .scalar(text), includesTime ? .datetime : .date)
            }
            cell.toolTip = content.displayName(property)
            let text = value.isEmpty ? cell.placeholder ?? "" : value.text
            let width = ceil(NSAttributedString(string: text, attributes: [.font: DateCell.font]).size().width) + 2
            let icon = NSImageView(image: NSImage(systemSymbolName: includesTime ? "clock" : "calendar", accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            icon.contentTintColor = .tertiaryLabelColor
            NSLayoutConstraint.activate([
                cell.widthAnchor.constraint(equalToConstant: width),
                cell.heightAnchor.constraint(equalToConstant: 22),
            ])
            let item = NSStackView(views: [icon, cell])
            item.spacing = 4
            return item
        }
        guard !value.isEmpty else { return nil }
        let label = NSTextField(labelWithString: "\(content.displayName(property))  \(value.text)")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    /// 下部のプロパティ。見出しの下に全文を折り返して出し、その場で書き換えられる。返事の欄は入力欄に見えるよう薄く塗る
    private func bodyItem(_ property: String, note: NoteRecord, context: NoteContext, content: Content, isReply: Bool) -> NSView {
        let name = content.displayName(property)
        let caption = NSTextField(labelWithString: name)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor

        let text = CardTextView()
        let key = Self.noteKey(property)
        // 複数行の書き方（`|` など）は元の書き方を崩さないよう書き換えない
        if let key, note.properties[key] == .other {
            text.string = "（この書き方の値はここでは表示できません。ノートを開いて確認してください）"
            text.isEditable = false
            text.textColor = .secondaryLabelColor
        } else {
            text.string = context.value(of: property).text
            text.isEditable = key != nil
            text.placeholder = isReply ? "\(name)を書く…（⌘Return で確定）" : "なし"
            text.onCommit = { [weak self] value in
                guard let key else { return }
                self?.onCommit?(note, key, .scalar(value), content.types[key] ?? .text)
            }
            text.onEndEditing = { [weak self] in
                if self?.needsRender == true { self?.render() }
            }
        }

        let box = NSView()
        text.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(text)
        let pad: CGFloat = isReply ? 8 : 0
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: pad * 0.75),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -pad * 0.75),
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: pad),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -pad),
        ])
        if isReply {
            box.wantsLayer = true
            box.layer?.cornerRadius = 6
            let fill = FilledView()
            fill.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(fill, positioned: .below, relativeTo: text)
            NSLayoutConstraint.activate([
                fill.topAnchor.constraint(equalTo: box.topAnchor),
                fill.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                fill.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                fill.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            ])
        }
        let section = NSStackView(views: [caption, box])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4
        box.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private static func chipsView(_ chips: [ChipsView.Chip]) -> ChipsView {
        let view = ChipsView()
        view.chips = chips
        let width = chips.reduce(0) { $0 + ceil(NSAttributedString(string: $1.label, attributes: [.font: ChipsView.font]).size().width) + 18 }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: max(width - 4, 1)),
            view.heightAnchor.constraint(equalToConstant: 22),
        ])
        return view
    }

    private static func noteKey(_ property: String) -> String? {
        property.hasPrefix("note.") ? String(property.dropFirst(5)) : nil
    }
}

private final class CardsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// カードの枠。返事待ちのカードは枠をオレンジにする
private final class CardView: NSView {
    var isAwaiting = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        // CGColor はライト・ダークで変わらないので、見た目が変わるたびにここで作り直す
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.025).cgColor
            layer?.borderColor = (isAwaiting ? NSColor.systemOrange.withAlphaComponent(0.7) : NSColor.labelColor.withAlphaComponent(0.12)).cgColor
        }
    }
}

/// 返事の欄の下地
private final class FilledView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        wantsLayer = true
        layer?.cornerRadius = 6
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
    }
}

/// 押すとノートを開くカードの題名（⌘クリックは新しいタブ）
private final class CardTitle: NSTextField {
    var onClick: ((_ newTab: Bool) -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.modifierFlags.contains(.command))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        onClick?(true)
    }
}

/// 押すとクロージャを呼ぶ領域（グループの見出し）
private final class ClickableView: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick() }

    @objc func click() { onClick() }
}

/// 中のビューを左から並べ、幅に収まらなければ折り返す
private final class FlowView: NSView {
    private let spacing: CGFloat = 10
    private let lineSpacing: CGFloat = 6
    private var lastHeight: CGFloat = -1

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: arrange(width: bounds.width, apply: false))
    }

    override func layout() {
        super.layout()
        let height = arrange(width: bounds.width, apply: true)
        if height != lastHeight {
            lastHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.fittingSize
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            if apply { view.frame = NSRect(x: x, y: y, width: min(size.width, max(width, 1)), height: size.height) }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return subviews.isEmpty ? 0 : y + lineHeight
    }
}

/// カードの下部の文字。全文を折り返して出し、高さは中身に合わせる。
/// 別の場所を押すか ⌘Return で確定し（変わっていれば `onCommit`）、Esc で書く前の文字に戻す
private final class CardTextView: NSTextView {
    var placeholder: String?
    var onCommit: ((String) -> Void)?
    var onEndEditing: (() -> Void)?
    private var original = ""
    private var cancelled = false

    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isVerticallyResizable = false
        isHorizontallyResizable = false
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        font = .systemFont(ofSize: 13)
        textColor = .maText
        textContainerInset = .zero
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        defaultParagraphStyle = paragraph
        typingAttributes[.paragraphStyle] = paragraph
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var string: String {
        didSet {
            if let paragraph = defaultParagraphStyle {
                textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (string as NSString).length))
            }
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else { return super.intrinsicContentSize }
        manager.ensureLayout(for: container)
        let height = string.isEmpty ? (font.map { manager.defaultLineHeight(for: $0) } ?? 17) : manager.usedRect(for: container).height
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { invalidateIntrinsicContentSize() }
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder else { return }
        NSAttributedString(string: placeholder, attributes: [
            .font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor,
        ]).draw(at: textContainerOrigin)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            original = string
            cancelled = false
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        guard resigned, isEditable else { return resigned }
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = !cancelled && value != original.trimmingCharacters(in: .whitespacesAndNewlines)
        // 移った先が決まってから書き込む（書き込みでカードを作り直すので、移った先の欄が書いている途中なら作り直しを待つ）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if changed { self.onCommit?(value) }
            self.onEndEditing?()
        }
        return resigned
    }

    override func cancelOperation(_ sender: Any?) {
        cancelled = true
        string = original
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 36 || event.keyCode == 76 {
            window?.makeFirstResponder(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
