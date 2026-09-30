import AppKit

/// `.base` を開いたタブ。ビューを切り替えて、条件に合うノートを表で見せる（いまは見るだけ）
final class BaseViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// vault のノートを読み直す
    var loadNotes: () async -> [NoteRecord] = { [] }
    var propertyTypes: () -> [String: PropertyType] = { [:] }
    var onOpenNote: ((URL, _ newTab: Bool) -> Void)?
    /// セルで値を変えたとき。ノートへの書き込みは呼び出し側が受け持つ
    var onSetProperty: ((URL, String, PropertyValue, PropertyType) -> Void)?

    private enum Row {
        case group(BaseValue, property: String, count: Int)
        /// グループごとに出す列の見出し（Notion と同じく、グループの下に列名を並べる）
        case header
        case note(NoteRecord)
    }

    private(set) var url: URL?
    private var base: BaseFile?
    private var notes: [NoteRecord] = []
    private var rows: [Row] = []
    /// 日付の列（値は時刻を含むかどうか）。型が登録されていない列は、値がすべて日付の形なら日付とみなす
    private var dateColumns: [String: Bool] = [:]
    private var selectedView = 0
    private var groups: [BaseFile.Group] = []
    /// 畳んだグループの値。`.base` のビューごとに `collapsedGroups` に記録する
    private var collapsed: Set<String> = []
    /// 列を作り直しているあいだは、幅や順番の変化を保存しない
    private var isSettingColumns = false
    private var saveColumnsTask: Task<Void, Never>?

    private let viewPicker = NSSegmentedControl()
    private let countLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let tableView = BaseTableView()
    private lazy var headerView = tableView.headerView
    private let scrollView = NSScrollView()

    private static let font = NSFont.systemFont(ofSize: 13)

    override func loadView() {
        viewPicker.segmentStyle = .rounded
        viewPicker.trackingMode = .selectOne
        viewPicker.target = self
        viewPicker.action = #selector(pickView(_:))
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true

        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        // 行の区切りは行ごとに薄く描く（SubtleRowView）。表の罫線だと行のない下の余白にも線が並ぶ
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 30
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clickRow(_:))
        tableView.doubleAction = #selector(doubleClickRow(_:))
        // グループの行は Notion と同じく、表と一緒に流す
        tableView.floatsGroupRows = false
        tableView.isHeaderRow = { [weak self] row in
            guard let self, self.rows.indices.contains(row), case .header = self.rows[row] else { return false }
            return true
        }
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let container = NSView()
        for view in [viewPicker, countLabel, messageLabel, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            viewPicker.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            viewPicker.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            countLabel.centerYAnchor.constraint(equalTo: viewPicker.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: viewPicker.trailingAnchor, constant: 12),
            messageLabel.topAnchor.constraint(equalTo: viewPicker.bottomAnchor, constant: 16),
            messageLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: viewPicker.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        view = container
    }

    func show(_ document: OpenDocument) {
        url = document.url
        do {
            base = try BaseFile(yaml: document.text)
        } catch {
            base = nil
            showMessage("\(error)")
            return
        }
        let names = base?.views.map(\.name) ?? []
        viewPicker.segmentCount = names.count
        for (index, name) in names.enumerated() {
            viewPicker.setLabel(name, forSegment: index)
            viewPicker.setWidth(0, forSegment: index)
        }
        selectedView = min(selectedView, max(0, names.count - 1))
        if !names.isEmpty { viewPicker.selectedSegment = selectedView }
        reload()
    }

    func focus() {
        view.window?.makeFirstResponder(tableView)
    }

    /// ノートを読み直して表を作り直す。タブを選んだときと、vault のファイルが変わったときに呼ぶ
    func reload() {
        guard base != nil else { return }
        Task {
            notes = await loadNotes()
            rebuild()
        }
    }

    @objc private func pickView(_ sender: NSSegmentedControl) {
        selectedView = sender.selectedSegment
        rebuild()
    }

    // MARK: - グループの開閉

    private static let collapsedKey = "collapsedGroups"

    private var collapsedStoreKey: String? {
        guard let url, let base, base.views.indices.contains(selectedView) else { return nil }
        return url.path + "#" + base.views[selectedView].name
    }

    private func loadCollapsed() {
        let stored = AppDefaults.shared.dictionary(forKey: Self.collapsedKey) as? [String: [String]] ?? [:]
        collapsed = Set(collapsedStoreKey.flatMap { stored[$0] } ?? [])
    }

    private func toggleGroup(_ value: BaseValue) {
        let key = value.text
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        if let storeKey = collapsedStoreKey {
            var stored = AppDefaults.shared.dictionary(forKey: Self.collapsedKey) as? [String: [String]] ?? [:]
            stored[storeKey] = collapsed.isEmpty ? nil : collapsed.sorted()
            AppDefaults.shared.set(stored, forKey: Self.collapsedKey)
        }
        layOutRows()
    }

    private func rebuild() {
        guard let base, base.views.indices.contains(selectedView) else {
            return showMessage("ビューがありません")
        }
        let view = base.views[selectedView]
        guard view.type == "table" else {
            return showMessage("このビューの種類（\(view.type)）はまだ表示できません")
        }
        do {
            groups = try base.evaluate(view, notes: notes, types: propertyTypes())
        } catch {
            return showMessage("フィルタを評価できません: \(error)")
        }
        messageLabel.isHidden = true
        scrollView.isHidden = false
        let types = propertyTypes()
        dateColumns = [:]
        for property in view.order {
            guard let key = Self.noteKey(property), base.schemas[property] == nil else { continue }
            switch types[key] {
            case .date?: dateColumns[property] = false
            case .datetime?: dateColumns[property] = true
            case nil:
                let values = notes.compactMap { note -> String? in
                    if case .scalar(let text)? = note.properties[key], !text.isEmpty { return text }
                    return nil
                }
                if !values.isEmpty, values.allSatisfy(PropertyType.looksLikeDate) {
                    dateColumns[property] = values.contains { $0.count > 10 }
                }
            default: break
            }
        }
        let total = groups.reduce(0) { $0 + $1.notes.count }
        countLabel.stringValue = "\(total) 件"
        // 列を足すと表は今の行数のままセルを作ろうとするので、列を作り直すあいだは行を空にしておく
        rows = []
        tableView.reloadData()
        setColumns(view, base: base)
        // グループに分けるときは、表の上の見出しの代わりにグループごとに列名を出す
        tableView.headerView = view.groupBy == nil ? headerView : nil
        loadCollapsed()
        layOutRows()
    }

    /// グループと開閉の状態から行を並べ直す
    private func layOutRows() {
        guard let base, base.views.indices.contains(selectedView) else { return }
        let groupBy = base.views[selectedView].groupBy
        rows = groups.flatMap { group -> [Row] in
            guard let value = group.value, let groupBy else { return group.notes.map(Row.note) }
            let title = Row.group(value, property: groupBy.property, count: group.notes.count)
            return collapsed.contains(value.text) ? [title] : [title, .header] + group.notes.map(Row.note)
        }
        tableView.reloadData()
        view.window?.invalidateCursorRects(for: tableView)
    }

    private func showMessage(_ message: String) {
        rows = []
        tableView.reloadData()
        countLabel.stringValue = ""
        messageLabel.stringValue = message
        messageLabel.isHidden = false
        scrollView.isHidden = true
    }

    /// 列は order の順。幅は columnSize、なければ 150pt
    private func setColumns(_ view: BaseFile.View, base: BaseFile) {
        isSettingColumns = true
        defer { isSettingColumns = false }
        let order = view.order.isEmpty ? ["file.name"] : view.order
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for property in order {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(property))
            column.title = base.displayName(of: property)
            column.width = view.columnSize[property] ?? 150
            column.minWidth = 40
            column.headerCell.font = .systemFont(ofSize: 12)
            tableView.addTableColumn(column)
        }
    }

    // MARK: - 列の幅と順番の保存

    func tableViewColumnDidMove(_ notification: Notification) { columnsDidChange() }
    func tableViewColumnDidResize(_ notification: Notification) { columnsDidChange() }

    /// ドラッグ中は何度も呼ばれるので、止まってから保存する
    private func columnsDidChange() {
        guard !isSettingColumns else { return }
        saveColumnsTask?.cancel()
        saveColumnsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveColumns()
        }
    }

    /// 今の列の順番と、変えた列の幅を、`.base` のそのビューの `order` と `columnSize` に書く（Obsidian と同じ場所）
    private func saveColumns() {
        guard let url, let base, base.views.indices.contains(selectedView) else { return }
        let view = base.views[selectedView]
        let ids = tableView.tableColumns.map(\.identifier.rawValue)
        let raw = Dictionary(zip(view.order, view.rawOrder), uniquingKeysWith: { first, _ in first })
        let order = ids.map { raw[$0] ?? $0 }
        var sizes: [String: Int] = [:]
        for column in tableView.tableColumns {
            let width = Int(column.width.rounded())
            if width != Int((view.columnSize[column.identifier.rawValue] ?? 150).rounded()) { sizes[column.identifier.rawValue] = width }
        }
        guard order != view.rawOrder || !sizes.isEmpty else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let updated = BaseFile.updatingColumns(text, view: selectedView, order: order, columnSize: sizes) else {
                return NSLog("列を保存できません（.base の形が想定と違います）: \(url.path)")
            }
            if updated != text { try updated.write(to: url, atomically: true, encoding: .utf8) }
            self.base = try BaseFile(yaml: updated)
        } catch {
            NSLog("列の保存に失敗: \(url.path): \(error)")
        }
    }

    // MARK: - 表

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    /// 選んだ行は濃い青で塗らず、薄い色を敷くだけにする（チップや文字の色が見えなくなるため）
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SubtleRowView()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .note = rows[row] { return true }
        return false
    }

    /// グループの行は上に余白を取り、前のグループと離す
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return row == 0 ? 36 : 56 }
        return tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let schemas = base?.schemas ?? [:]
        let field = NSTextField(labelWithString: "")
        field.font = Self.font
        field.lineBreakMode = .byTruncatingTail
        field.textColor = .maText
        let content: NSView
        switch rows[row] {
        case .group(let value, let property, let count):
            // グループの行は列をまたいで1つのビューになる（tableColumn が nil）
            guard tableColumn == nil else { return nil }
            field.stringValue = "\(count)"
            field.textColor = .secondaryLabelColor
            let title: NSView
            if let schema = schemas[property], !value.isEmpty {
                let chips = ChipsView()
                chips.chips = schema.chips(for: value)
                title = chips
            } else {
                let label = NSTextField(labelWithString: value.isEmpty ? "（なし）" : value.text)
                label.font = .systemFont(ofSize: 13, weight: .semibold)
                label.textColor = .maText
                title = label
            }
            let disclosure = ClosureButton(image: Self.disclosureImage(collapsed: collapsed.contains(value.text))) { [weak self] in
                self?.toggleGroup(value)
            }
            disclosure.contentTintColor = .secondaryLabelColor
            disclosure.setAccessibilityLabel(collapsed.contains(value.text) ? "グループを開く" : "グループを畳む")
            disclosure.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let stack = NSStackView(views: [disclosure, title, field])
            stack.spacing = 8
            stack.setCustomSpacing(6, after: disclosure)
            if let chips = title as? ChipsView {
                chips.widthAnchor.constraint(equalToConstant: chips.chips.reduce(0) { $0 + Self.chipWidth($1) }).isActive = true
                chips.heightAnchor.constraint(equalToConstant: 24).isActive = true
            }
            content = stack
        case .header:
            guard let property = tableColumn?.identifier.rawValue else { return nil }
            let icon = NSImageView(image: NSImage(systemSymbolName: symbolName(of: property), accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            icon.contentTintColor = .tertiaryLabelColor
            field.stringValue = tableColumn?.title ?? property
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            // 列が狭いときは列名のほうを切り詰め、アイコンは残す
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [icon, field])
            stack.spacing = 5
            content = stack
        case .note(let note):
            guard let property = tableColumn?.identifier.rawValue else { return nil }
            let value = NoteContext(note: note, types: propertyTypes(), schemas: schemas).value(of: property)
            if property == "file.name" || property == "file.basename" {
                let link = LinkLabel(labelWithString: note.basename)
                link.font = Self.font
                link.lineBreakMode = .byTruncatingTail
                link.textColor = .maLink
                content = link
            } else if let includesTime = dateColumns[property], let key = Self.noteKey(property) {
                let cell = DateCell()
                cell.includesTime = includesTime
                cell.placeholder = nil
                cell.text = value.text
                cell.onChange = { [weak self] text in
                    self?.commit(note, key, .scalar(text), type: includesTime ? .datetime : .date)
                }
                cell.heightAnchor.constraint(equalToConstant: 24).isActive = true
                content = cell
            } else if let schema = schemas[property] {
                let chips = ChipsView()
                chips.chips = schema.chips(for: value)
                chips.heightAnchor.constraint(equalToConstant: 24).isActive = true
                chips.onClick = { [weak self] view in
                    guard let self, let key = Self.noteKey(property) else { return }
                    schema.optionsMenu(for: note.properties[key] ?? .scalar("")) { [weak self] value in
                        self?.commit(note, key, value, type: schema.kind == .multiSelect ? .multitext : .text)
                    }.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 2), in: view)
                }
                content = chips
            } else if let key = Self.noteKey(property), note.properties[key] != .other {
                let types = propertyTypes()
                if types[key] == .checkbox {
                    let checkbox = CellCheckbox { [weak self] on in
                        self?.commit(note, key, .scalar(on ? "true" : "false"), type: .checkbox)
                    }
                    checkbox.state = value == .bool(true) ? .on : .off
                    content = checkbox
                } else {
                    let current = note.properties[key] ?? .scalar("")
                    let isList = types[key]?.isList ?? { if case .list = current { true } else { false } }()
                    let editable = CellTextField(value.text) { [weak self] text in
                        let value: PropertyValue = isList
                            ? .list(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                            : .scalar(text.trimmingCharacters(in: .whitespaces))
                        guard value != current, !(value.text.isEmpty && current.text.isEmpty) else { return }
                        self?.commit(note, key, value, type: types[key] ?? (isList ? .multitext : .text))
                    }
                    editable.font = Self.font
                    content = editable
                }
            } else {
                field.stringValue = value.text
                content = field
            }
        }
        let cell = NSTableCellView()
        cell.textField = content as? CellTextField
        cell.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        // グループの行は上に取った余白の下、見出しの行の高さの中央に置く
        let isGroup = if case .group = rows[row] { true } else { false }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: isGroup ? 4 : 8),
            content.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            isGroup
                ? content.centerYAnchor.constraint(equalTo: cell.bottomAnchor, constant: -tableView.rowHeight / 2)
                : content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if content is ChipsView || content is CellTextField || content is DateCell {
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8).isActive = true
        }
        return cell
    }

    private static func disclosureImage(collapsed: Bool) -> NSImage {
        let image = NSImage(systemSymbolName: collapsed ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill", accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 9, weight: .regular)) ?? image
    }

    /// 列の見出しに添える型のアイコン
    private func symbolName(of property: String) -> String {
        if property == "file.name" || property == "file.basename" { return "textformat" }
        if property.hasPrefix("file.") { return dateColumns[property] != nil || property.hasSuffix("time") ? "clock" : "doc" }
        if let schema = base?.schemas[property] {
            switch schema.kind {
            case .status: return "circle.dashed"
            case .select: return "chevron.down.circle"
            case .multiSelect: return "list.bullet"
            }
        }
        if let includesTime = dateColumns[property] { return includesTime ? "clock" : "calendar" }
        guard let key = Self.noteKey(property) else { return "text.alignleft" }
        return propertyTypes()[key]?.symbolName ?? "text.alignleft"
    }

    private static func chipWidth(_ chip: ChipsView.Chip) -> CGFloat {
        ceil(NSAttributedString(string: chip.label, attributes: [.font: ChipsView.font]).size().width) + 18
    }

    /// `note.ステータス` → `ステータス`。ノートのプロパティでなければ nil
    private static func noteKey(_ property: String) -> String? {
        property.hasPrefix("note.") ? String(property.dropFirst(5)) : nil
    }

    /// セルで変えた値をノートに書き、そのノートだけ読み直して表を作り直す
    private func commit(_ note: NoteRecord, _ key: String, _ value: PropertyValue, type: PropertyType) {
        onSetProperty?(note.url, key, value, type)
        let root = URL(fileURLWithPath: String(note.url.path.dropLast(note.path.count + 1)), isDirectory: true)
        if let index = notes.firstIndex(where: { $0.url.path == note.url.path }),
           let updated = NoteRecord.load([note.url], root: root).first {
            notes[index] = updated
        }
        rebuild()
    }

    /// テキストのセルはダブルクリックで編集する
    @objc private func doubleClickRow(_ sender: Any?) {
        let row = tableView.clickedRow, column = tableView.clickedColumn
        guard row >= 0, column >= 0, tableView.view(atColumn: column, row: row, makeIfNecessary: false)
            .flatMap({ ($0 as? NSTableCellView)?.textField as? CellTextField }) != nil
        else { return }
        tableView.editColumn(column, row: row, with: nil, select: true)
    }

    /// ノートの名前の列をクリックしたらノートを開く（⌘クリックは新しいタブ）
    @objc private func clickRow(_ sender: Any?) {
        let row = tableView.clickedRow, column = tableView.clickedColumn
        if rows.indices.contains(row), case .group(let value, _, _) = rows[row] { return toggleGroup(value) }
        guard rows.indices.contains(row), tableView.tableColumns.indices.contains(column),
              case .note(let note) = rows[row],
              ["file.name", "file.basename"].contains(tableView.tableColumns[column].identifier.rawValue)
        else { return }
        onOpenNote?(note.url, NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }
}

/// 押したらクロージャを呼ぶ、枠のないボタン
private final class ClosureButton: NSButton {
    private let onPress: () -> Void

    init(image: NSImage, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        self.image = image
        isBordered = false
        target = self
        action = #selector(press)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func press() { onPress() }
}

/// グループごとの列の見出しの行で、列の境界のドラッグで幅を、見出しのドラッグで順番を変えられる表
/// （グループに分けたときは表の上の見出しを出さないので、その代わり）
private final class BaseTableView: NSTableView {
    var isHeaderRow: (Int) -> Bool = { _ in false }

    private static let grabWidth: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0, isHeaderRow(row) else { return super.mouseDown(with: event) }
        if let column = resizableColumn(at: point) {
            trackResize(of: tableColumns[column], from: point)
        } else if case let column = self.column(at: point), column >= 0, allowsColumnReordering {
            trackMove(of: column)
        }
    }

    /// 境界の左の列（右端が point の近くにある列）
    private func resizableColumn(at point: NSPoint) -> Int? {
        tableColumns.indices.first { abs(rect(ofColumn: $0).maxX - point.x) <= Self.grabWidth }
    }

    private func trackResize(of column: NSTableColumn, from start: NSPoint) {
        let startWidth = column.width
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), event.type == .leftMouseDragged {
            let x = convert(event.locationInWindow, from: nil).x
            column.width = min(column.maxWidth, max(column.minWidth, (startWidth + x - start.x).rounded()))
        }
        window?.invalidateCursorRects(for: self)
    }

    /// 掴んだ列を、ポインタのある列の位置へ移していく
    private func trackMove(of start: Int) {
        var current = start
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), event.type == .leftMouseDragged {
            autoscroll(with: event)
            let target = column(at: convert(event.locationInWindow, from: nil))
            guard target >= 0, target != current else { continue }
            moveColumn(current, toColumn: target)
            current = target
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let visible = rows(in: visibleRect)
        for row in visible.lowerBound..<visible.upperBound where isHeaderRow(row) {
            let rowRect = rect(ofRow: row)
            for column in tableColumns.indices {
                let x = rect(ofColumn: column).maxX
                addCursorRect(NSRect(x: x - Self.grabWidth, y: rowRect.minY, width: Self.grabWidth * 2, height: rowRect.height), cursor: .resizeLeftRight)
            }
        }
    }
}

/// 表のセルで編集するテキスト。Enter か別の場所をクリックしたら確定し、Esc で元に戻す
private final class CellTextField: NSTextField, NSTextFieldDelegate {
    private let original: String
    private let onCommit: (String) -> Void
    private var cancelled = false

    init(_ text: String, onCommit: @escaping (String) -> Void) {
        original = text
        self.onCommit = onCommit
        super.init(frame: .zero)
        stringValue = text
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        textColor = .maText
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidEndEditing(_ notification: Notification) {
        if cancelled {
            cancelled = false
            stringValue = original
            return
        }
        if stringValue != original { onCommit(stringValue) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelled = true
        window?.makeFirstResponder(nil)
        return true
    }
}

/// 表のセルのチェックボックス
private final class CellCheckbox: NSButton {
    private let onToggle: (Bool) -> Void

    init(onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        setButtonType(.switch)
        title = ""
        target = self
        action = #selector(toggle)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() { onToggle(state == .on) }
}

/// 選んだ行を薄い色で塗り、下端に細い区切り線を引く行
private final class SubtleRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isGroupRowStyle {
            // 既定のグループの行の灰色の帯は描かない
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        // withAlphaComponent は不透明度を置き換えるので、元から薄い separatorColor に使うと逆に濃くなる
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: bounds.maxY - 1 / scale, width: bounds.width, height: 1 / scale).fill()
    }

    // 既定の区切り線は濃いので描かない（上の drawBackground で薄い線を引く）
    override func drawSeparator(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        bounds.fill()
    }

    // 濃い色の上に載せる前提の白い文字に切り替えさせない
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// 押すとノートを開く名前。指のカーソルにしてリンクだとわかるようにする
private final class LinkLabel: NSTextField {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
