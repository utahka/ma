import AppKit

/// ノートの先頭に出すプロパティ欄。フロントマターの文字は本文の中に残したまま隠し、その位置にこのビューを重ねる。
/// 値を変えたら `on…` で知らせ、エディタがフロントマターの該当する行を書き換える（取り消し・自動保存は本文の編集と同じ）
@MainActor
final class PropertiesView: NSView, NSTextFieldDelegate, NSTokenFieldDelegate {
    var onSet: ((_ key: String, PropertyValue, PropertyType) -> Void)?
    var onAdd: ((_ key: String) -> Void)?
    var onCancelAdd: (() -> Void)?
    var onRemove: ((_ key: String) -> Void)?
    var onRename: ((_ key: String, _ newKey: String) -> Void)?
    var onChangeType: ((_ key: String, PropertyType) -> Void)?

    static let rowHeight: CGFloat = 30
    private static let keyWidth: CGFloat = 150
    private static let font = NSFont.systemFont(ofSize: 13)
    /// 欄と本文のあいだの余白
    private static let bottomMargin: CGFloat = 20

    @MainActor
    private final class Row {
        let key: String
        let type: PropertyType
        /// `.base` の `ma:` の型。あれば選択肢のチップで表示する
        let schema: PropertySchema?
        var value: PropertyValue
        let icon = NSButton()
        let keyField = NSTextField(labelWithString: "")
        var valueControl: NSView

        init(key: String, type: PropertyType, schema: PropertySchema?, value: PropertyValue, valueControl: NSView) {
            self.key = key
            self.type = type
            self.schema = schema
            self.value = value
            self.valueControl = valueControl
        }
    }

    private var rows: [Row] = []
    private let addButton = NSButton()
    /// 追加中の新しいプロパティの名前の欄
    private var draftField: NSTextField?
    private var renamingRow: Row?
    /// 次の update で値の欄にカーソルを入れるキー（追加した直後）
    private var focusKey: String?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addButton.title = "プロパティを追加"
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.isBordered = false
        addButton.contentTintColor = .secondaryLabelColor
        addButton.font = Self.font
        addButton.target = self
        addButton.action = #selector(beginAdding)
        addSubview(addButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 欄の高さ（本文との余白を含む）
    var height: CGFloat {
        CGFloat(rows.count + (draftField == nil ? 0 : 1) + 1) * Self.rowHeight + Self.bottomMargin
    }

    /// フロントマターの内容に合わせる。キーや型が変わったときだけ行を作り直し、
    /// そうでなければ編集中でない欄の値だけを入れ替える（入力中の欄を壊さないため）。
    /// `schemas`（ノートが対象の `.base` の型）にあってフロントマターにないプロパティは、空の欄として後ろに足す
    func update(entries: [FrontmatterEntry], types: PropertyTypes?, schemas: [String: PropertySchema] = [:]) {
        let missing = schemas.keys.filter { key in !entries.contains { $0.key == key } }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { key in
                FrontmatterEntry(key: key, value: schemas[key]?.kind == .multiSelect ? .list([]) : .scalar(""),
                                 range: NSRange(location: NSNotFound, length: 0))
            }
        let items = (entries + missing).map { entry in
            (entry, types?.type(of: entry.key, value: entry.value) ?? .text, schemas[entry.key])
        }
        let sameShape = items.count == rows.count
            && zip(items, rows).allSatisfy { $0.0.key == $1.key && $0.1 == $1.type && $0.2 == $1.schema }
        if sameShape {
            for ((entry, _, _), row) in zip(items, rows) where row.value != entry.value {
                row.value = entry.value
                if !isEditing(row.valueControl) { fill(row) }
            }
        } else {
            rows.forEach { row in [row.icon, row.keyField, row.valueControl].forEach { $0.removeFromSuperview() } }
            rows = items.map { makeRow($0.0, type: $0.1, schema: $0.2) }
            needsLayout = true
        }
        if let focusKey, let row = rows.first(where: { $0.key == focusKey }) {
            self.focusKey = nil
            layoutSubtreeIfNeeded()
            window?.makeFirstResponder(row.valueControl)
        }
    }

    // MARK: - 行

    private func makeRow(_ entry: FrontmatterEntry, type: PropertyType, schema: PropertySchema?) -> Row {
        let control: NSView
        switch (type, entry.value) {
        case _ where schema != nil:
            let chips = ChipsView()
            chips.placeholder = "空"
            chips.onClick = { [weak self] view in self?.showOptions(for: view) }
            control = chips
        case (_, .other):
            let label = NSTextField(labelWithString: "（⌘E のソース表示で編集）")
            label.textColor = .tertiaryLabelColor
            control = label
        case (.checkbox, _):
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCheckbox(_:)))
            control = button
        case (.date, _), (.datetime, _):
            let cell = DateCell()
            cell.includesTime = type == .datetime
            cell.onChange = { [weak self] text in self?.onSet?(entry.key, .scalar(text), type) }
            control = cell
        case (let type, _) where type.isList:
            let field = NSTokenField()
            field.tokenStyle = .rounded
            field.delegate = self
            // 読点や改行で区切らず、Enter とカンマで項目を分ける
            field.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
            control = field
        default:
            let field = NSTextField()
            field.delegate = self
            switch type {
            case .date: field.placeholderString = "YYYY-MM-DD"
            case .datetime: field.placeholderString = "YYYY-MM-DDTHH:mm"
            case .number: field.placeholderString = "数値"
            default: field.placeholderString = "空"
            }
            control = field
        }
        if let field = control as? NSTextField, field.isEditable {
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.cell?.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
        }
        (control as? NSControl)?.font = Self.font

        let row = Row(key: entry.key, type: type, schema: schema, value: entry.value, valueControl: control)
        let symbol = schema.map { schema in
            switch schema.kind {
            case .select: "chevron.down.circle"
            case .multiSelect: "list.bullet.circle"
            case .status: "circle.lefthalf.filled"
            }
        } ?? type.symbolName
        row.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: type.label)
        row.icon.isBordered = false
        row.icon.contentTintColor = .tertiaryLabelColor
        row.icon.toolTip = type.label
        row.icon.target = self
        row.icon.action = #selector(showMenu(_:))
        row.keyField.stringValue = entry.key
        row.keyField.font = Self.font
        row.keyField.textColor = .secondaryLabelColor
        row.keyField.lineBreakMode = .byTruncatingTail
        row.keyField.menu = menu(for: row)
        [row.icon, row.keyField, control].forEach(addSubview)
        fill(row)
        return row
    }

    private func fill(_ row: Row) {
        switch row.valueControl {
        case let cell as DateCell:
            cell.text = row.value.text
        case let chips as ChipsView:
            guard let schema = row.schema else { break }
            // 値がなければ既定値を入っているものとして見せる（ファイルには書かない）
            var value: BaseValue
            switch row.value {
            case .list(let items): value = .list(items.map { .string($0) })
            case .scalar(let text): value = text.isEmpty ? .null : .string(text)
            case .other: value = .null
            }
            if value.isEmpty, let fallback = schema.defaultValue { value = .string(fallback) }
            chips.chips = schema.chips(for: value)
        case let field as NSTokenField:
            if case .list(let items) = row.value { field.objectValue = items } else { field.objectValue = row.value.text.isEmpty ? [] : [row.value.text] }
        case let button as NSButton:
            button.state = row.value.text == "true" ? .on : .off
        case let field as NSTextField where field.isEditable:
            field.stringValue = row.value.text
            field.textColor = .maText
        default:
            break
        }
    }

    private func isEditing(_ control: NSView) -> Bool {
        (control as? NSTextField)?.currentEditor() != nil
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        func place(icon: NSView?, key: NSView, value: NSView?) {
            let middle = y + Self.rowHeight / 2
            icon?.frame = NSRect(x: 0, y: middle - 9, width: 18, height: 18)
            key.frame = NSRect(x: 24, y: middle - 9, width: Self.keyWidth - 30, height: 18)
            value?.frame = NSRect(x: Self.keyWidth, y: middle - 11, width: max(40, bounds.width - Self.keyWidth), height: 22)
            y += Self.rowHeight
        }
        for row in rows {
            if row === renamingRow, let draftField {
                place(icon: row.icon, key: draftField, value: row.valueControl)
                row.keyField.isHidden = true
            } else {
                row.keyField.isHidden = false
                place(icon: row.icon, key: row.keyField, value: row.valueControl)
            }
        }
        if let draftField, renamingRow == nil { place(icon: nil, key: draftField, value: nil) }
        addButton.sizeToFit()
        addButton.frame.origin = NSPoint(x: 0, y: y + (Self.rowHeight - addButton.frame.height) / 2)
    }

    // MARK: - 追加・名前の変更

    @objc func beginAdding() {
        if let draftField {
            window?.makeFirstResponder(draftField)
            return
        }
        startDraft(placeholder: "プロパティ名", text: "")
    }

    private func startDraft(placeholder: String, text: String) {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.font = Self.font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        addSubview(field)
        draftField = field
        needsLayout = true
        onHeightChange?()
        window?.makeFirstResponder(field)
    }

    /// 欄の高さが変わったとき（追加中の行が出たり消えたりしたとき）
    var onHeightChange: (() -> Void)?

    private func finishDraft(commit: Bool) {
        guard let field = draftField else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let renaming = renamingRow
        draftField = nil
        renamingRow = nil
        field.delegate = nil
        field.removeFromSuperview()
        needsLayout = true
        let exists = rows.contains { $0.key == name }
        if let renaming {
            if commit, !name.isEmpty, !exists { onRename?(renaming.key, name) } else { onHeightChange?() }
        } else if commit, !name.isEmpty {
            if exists {
                focusKey = name
                onHeightChange?()
            } else {
                focusKey = name
                onAdd?(name)
            }
        } else {
            onCancelAdd?()
            onHeightChange?()
        }
    }

    // MARK: - 型・削除のメニュー

    private func menu(for row: Row) -> NSMenu {
        let menu = NSMenu()
        let typeMenu = NSMenu()
        for type in PropertyType.choosable {
            let item = typeMenu.addItem(withTitle: type.label, action: #selector(chooseType(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: type.symbolName, accessibilityDescription: nil)
            item.state = type == row.type ? .on : .off
            item.representedObject = (row.key, type)
            item.target = self
        }
        let typeItem = menu.addItem(withTitle: "型", action: nil, keyEquivalent: "")
        typeItem.submenu = typeMenu
        let rename = menu.addItem(withTitle: "名前を変更", action: #selector(rename(_:)), keyEquivalent: "")
        rename.representedObject = row.key
        rename.target = self
        menu.addItem(.separator())
        let remove = menu.addItem(withTitle: "削除", action: #selector(remove(_:)), keyEquivalent: "")
        remove.representedObject = row.key
        remove.target = self
        return menu
    }

    @objc private func showMenu(_ sender: NSButton) {
        guard let row = rows.first(where: { $0.icon === sender }) else { return }
        menu(for: row).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func chooseType(_ sender: NSMenuItem) {
        guard let (key, type) = sender.representedObject as? (String, PropertyType) else { return }
        onChangeType?(key, type)
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let row = rows.first(where: { $0.key == key }) else { return }
        finishDraft(commit: false)
        renamingRow = row
        startDraft(placeholder: key, text: key)
    }

    @objc private func remove(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        onRemove?(key)
    }

    // MARK: - 選択肢

    /// チップを押したら選択肢のメニューを出す
    private func showOptions(for view: ChipsView) {
        guard let row = rows.first(where: { $0.valueControl === view }), let schema = row.schema else { return }
        let menu = schema.optionsMenu(for: row.value) { [weak self] value in
            self?.onSet?(row.key, value, schema.kind == .multiSelect ? .multitext : .text)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 2), in: view)
    }

    // MARK: - 値の確定

    @objc private func toggleCheckbox(_ sender: NSButton) {
        guard let row = rows.first(where: { $0.valueControl === sender }) else { return }
        onSet?(row.key, .scalar(sender.state == .on ? "true" : "false"), row.type)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === draftField { return finishDraft(commit: true) }
        guard let row = rows.first(where: { $0.valueControl === field }) else { return }
        let value: PropertyValue
        if let tokens = field as? NSTokenField {
            let items = (tokens.objectValue as? [Any] ?? []).map { "\($0)".trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            value = .list(items)
        } else {
            value = .scalar(field.stringValue.trimmingCharacters(in: .whitespaces))
        }
        // 1つの値のプロパティに空のリストが書かれていた場合などを含め、見た目が同じなら書き換えない
        if value == row.value || (value.text.isEmpty && row.value.text.isEmpty) { return }
        onSet?(row.key, value, row.type)
    }

    /// Esc で追加・名前の変更を取り消す
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === draftField, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finishDraft(commit: false)
        return true
    }
}
