import AppKit

/// ビューのフィルタを編集するポップオーバーの中身。変えるたびに `onChange` で新しいフィルタを渡す（nil はフィルタなし）。
/// `and` / `or` の中の「プロパティ・演算子・値」で表せる式は選ぶ形で、それ以外の式はその文字列を直接編集する
final class BaseFilterEditor: NSViewController {
    /// 条件で選べるプロパティ（`.base` に書く名前と、表示名）
    struct Property {
        let name: String
        let title: String
    }

    var onChange: ((BaseFilterNode?) -> Void)?

    /// 編集中の木。GUI の行は `condition` を持ち、式の文字列の行は持たない
    private final class Item {
        var conjunction: BaseFilterNode.Conjunction?
        var children: [Item] = []
        var text = ""
        var condition: BaseFilterCondition?
        weak var errorLabel: NSTextField?

        init(group conjunction: BaseFilterNode.Conjunction, children: [Item] = []) {
            self.conjunction = conjunction
            self.children = children
        }

        init(text: String, condition: BaseFilterCondition?) {
            self.text = text
            self.condition = condition
        }

        init(_ node: BaseFilterNode) {
            switch node {
            case .expression(let text):
                self.text = text
                condition = BaseFilterCondition(text)
            case .group(let conjunction, let children):
                self.conjunction = conjunction
                self.children = children.map(Item.init)
            }
        }

        /// 書きかけ（空）の行は含めない
        var node: BaseFilterNode? {
            if let conjunction { return .group(conjunction, children.compactMap(\.node)) }
            let text = text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .expression(text)
        }
    }

    private let root: Item
    private let properties: [Property]
    private let values: (String) -> [String]
    private var saved: BaseFilterNode?
    private let stack = NSStackView()

    private static let font = NSFont.systemFont(ofSize: 12)
    private static let propertyWidth: CGFloat = 130
    private static let operatorWidth: CGFloat = 130
    private static let valueWidth: CGFloat = 190
    private static let spacing: CGFloat = 6

    /// `values` はプロパティの名前から、値の候補を返す
    init(filter: BaseFilterNode?, properties: [Property], values: @escaping (String) -> [String]) {
        saved = filter
        switch filter {
        case .group?: root = Item(filter!)
        case .expression?: root = Item(group: .and, children: [Item(filter!)])
        case nil: root = Item(group: .and)
        }
        // 書かれている条件のプロパティが候補になければ足す
        var properties = properties
        func collect(_ item: Item) {
            if let name = item.condition?.property, !properties.contains(where: { $0.name == name }) {
                properties.append(Property(name: name, title: name))
            }
            item.children.forEach(collect)
        }
        collect(root)
        self.properties = properties
        self.values = values
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        // 中身の大きさでポップオーバーの大きさが決まるよう、四辺を固定する（行を消したときに縮める）
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view = container
        render()
    }

    /// 閉じるときに、編集中の文字を確定させる
    override func viewWillDisappear() {
        super.viewWillDisappear()
        view.window?.makeFirstResponder(nil)
    }

    // MARK: - 組み立て

    private func render() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        let title = NSTextField(labelWithString: "このビューのフィルタ")
        title.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(groupView(root, isRoot: true))
        let note = NSTextField(labelWithString: "ファイルの先頭のフィルタ（全体）は変わりません")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(note)
        updateErrors()
        preferredContentSize = stack.fittingSize
    }

    private func groupView(_ group: Item, isRoot: Bool) -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = Self.spacing

        let conjunction = ClosurePopUp(titles: ["すべてを満たす", "いずれかを満たす", "どれも満たさない"]) { [weak self] index in
            group.conjunction = BaseFilterNode.Conjunction.allCases[index]
            self?.commit()
        }
        conjunction.selectItem(at: BaseFilterNode.Conjunction.allCases.firstIndex(of: group.conjunction ?? .and) ?? 0)
        var header: [NSView] = [conjunction]
        if !isRoot {
            header.append(removeButton { [weak self] in self?.remove(group) })
        }
        box.addArrangedSubview(row(header))

        if group.children.isEmpty {
            let empty = NSTextField(labelWithString: isRoot ? "条件はありません。すべてのノートを表示します" : "条件はありません")
            empty.font = Self.font
            empty.textColor = .secondaryLabelColor
            box.addArrangedSubview(empty)
        }
        for child in group.children {
            if child.conjunction != nil {
                let nested = groupView(child, isRoot: false)
                let frame = NSView()
                frame.wantsLayer = true
                frame.layer?.cornerRadius = 6
                frame.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
                nested.translatesAutoresizingMaskIntoConstraints = false
                frame.addSubview(nested)
                NSLayoutConstraint.activate([
                    nested.topAnchor.constraint(equalTo: frame.topAnchor, constant: 8),
                    nested.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -8),
                    nested.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 10),
                    nested.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -10),
                ])
                box.addArrangedSubview(frame)
            } else if child.condition != nil {
                box.addArrangedSubview(conditionRow(child, in: group))
            } else {
                box.addArrangedSubview(expressionRow(child, in: group))
            }
        }

        var buttons: [NSView] = [
            addButton("条件を追加") { [weak self] in self?.addCondition(to: group) },
            addButton("式を追加") { [weak self] in self?.add(Item(text: "", condition: nil), to: group) },
        ]
        if isRoot {
            buttons.append(addButton("グループを追加") { [weak self] in self?.add(Item(group: .or), to: group) })
        }
        box.addArrangedSubview(row(buttons))
        return box
    }

    /// プロパティ・演算子・値を選ぶ行
    private func conditionRow(_ item: Item, in group: Item) -> NSView {
        guard let condition = item.condition else { return NSView() }
        let valueField = ClosureComboBox { [weak self] text in
            item.condition?.value = text
            self?.conditionDidChange(item)
        }
        valueField.font = Self.font
        valueField.placeholderString = "値"
        valueField.stringValue = condition.value
        Self.setVisible(valueField, condition.op.needsValue)
        valueField.addItems(withObjectValues: values(condition.property))
        valueField.widthAnchor.constraint(equalToConstant: Self.valueWidth).isActive = true

        let property = ClosurePopUp(titles: properties.map(\.title)) { [weak self] index in
            guard let self else { return }
            item.condition?.property = self.properties[index].name
            valueField.removeAllItems()
            valueField.addItems(withObjectValues: self.values(self.properties[index].name))
            self.conditionDidChange(item)
        }
        property.selectItem(at: properties.firstIndex { $0.name == condition.property } ?? 0)
        property.widthAnchor.constraint(equalToConstant: Self.propertyWidth).isActive = true

        let operators = BaseFilterCondition.Operator.allCases
        let op = ClosurePopUp(titles: operators.map(\.title)) { [weak self] index in
            item.condition?.op = operators[index]
            Self.setVisible(valueField, operators[index].needsValue)
            self?.conditionDidChange(item)
        }
        op.selectItem(at: operators.firstIndex(of: condition.op) ?? 0)
        op.widthAnchor.constraint(equalToConstant: Self.operatorWidth).isActive = true

        return row([property, op, valueField, removeButton { [weak self] in self?.remove(item) }])
    }

    /// 値の要らない演算子では値の欄を見せない。隠す（isHidden）と行が詰まって削除ボタンの位置がずれるので、透明にする
    private static func setVisible(_ field: NSComboBox, _ visible: Bool) {
        field.alphaValue = visible ? 1 : 0
        field.isEnabled = visible
    }

    /// GUI で表せない式を、文字列のまま編集する行。読めない式は下にエラーを出す
    private func expressionRow(_ item: Item, in group: Item) -> NSView {
        let field = ClosureTextField { [weak self] text in
            item.text = text
            self?.commit()
        }
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = "式（例: ステータス.contains(\"完了\")）"
        field.stringValue = item.text
        field.widthAnchor.constraint(equalToConstant: Self.propertyWidth + Self.operatorWidth + Self.valueWidth + Self.spacing * 2).isActive = true

        let error = NSTextField(wrappingLabelWithString: "")
        error.font = .systemFont(ofSize: 11)
        error.textColor = .systemRed
        error.isHidden = true
        error.preferredMaxLayoutWidth = Self.propertyWidth + Self.operatorWidth + Self.valueWidth
        item.errorLabel = error

        let column = NSStackView(views: [row([field, removeButton { [weak self] in self?.remove(item) }]), error])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        return column
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = Self.spacing
        return row
    }

    private func removeButton(_ action: @escaping () -> Void) -> NSView {
        let button = ClosureButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "削除")!, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "削除"
        return button
    }

    private func addButton(_ title: String, _ action: @escaping () -> Void) -> NSView {
        let button = ClosureButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!, action: action)
        button.title = title
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.font = Self.font
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    // MARK: - 変更

    private func addCondition(to group: Item) {
        let property = properties.first?.name ?? "file.name"
        add(Item(text: "", condition: BaseFilterCondition(property: property, op: .equals, value: "")), to: group)
    }

    private func add(_ item: Item, to group: Item) {
        group.children.append(item)
        render()
        commit()
    }

    private func remove(_ item: Item) {
        func walk(_ group: Item) {
            group.children.removeAll { $0 === item }
            group.children.forEach(walk)
        }
        walk(root)
        render()
        commit()
    }

    private func conditionDidChange(_ item: Item) {
        item.text = item.condition?.expression ?? ""
        commit()
    }

    /// 読めない式があれば書き戻さない
    private func commit() {
        guard updateErrors() else { return }
        let node = root.node.flatMap { node -> BaseFilterNode? in
            if case .group(_, let children) = node, children.isEmpty { return nil }
            return node
        }
        guard node != saved else { return }
        saved = node
        onChange?(node)
    }

    /// 式の文字列の行にエラーを出す。すべて読めれば true
    @discardableResult
    private func updateErrors() -> Bool {
        var valid = true
        func walk(_ item: Item) {
            item.children.forEach(walk)
            guard item.conjunction == nil, item.condition == nil else { return }
            let message = Self.error(in: item.text).map { $0 + "（直すまで保存しません）" }
            item.errorLabel?.stringValue = message ?? ""
            item.errorLabel?.isHidden = message == nil
            if message != nil { valid = false }
        }
        walk(root)
        preferredContentSize = stack.fittingSize
        return valid
    }

    /// 読めない式・対応していない関数なら、その説明
    static func error(in text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        do {
            let expression = try BaseExpression.parse(text)
            // 対応していない関数は評価して初めてわかるので、値のないノートで一度評価する
            let probe = NoteRecord(url: URL(fileURLWithPath: "/"), path: "", properties: [:],
                                   created: .distantPast, modified: .distantPast, size: 0)
            _ = try expression.evaluate(NoteContext(note: probe, types: [:]))
            return nil
        } catch {
            return "\(error)"
        }
    }

    // MARK: - 候補

    /// 条件で選べるプロパティ。ビューの列、`.base` に定義のあるもの、対象のノートにあるもの、ファイルの属性の順
    static func properties(base: BaseFile, view: BaseFile.View, notes: [NoteRecord], types: [String: PropertyType]) -> [Property] {
        var names: [String] = []
        func add(_ id: String) {
            let name = id.hasPrefix("note.") ? String(id.dropFirst(5)) : id
            if !names.contains(name) { names.append(name) }
        }
        view.order.forEach(add)
        (Array(base.schemas.keys) + Array(base.displayNames.keys)).sorted().forEach(add)
        let keys = Set(targets(base: base, notes: notes, types: types).flatMap(\.properties.keys))
        keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.forEach { add("note." + $0) }
        ["file.name", "file.folder", "file.path", "file.ext", "file.ctime", "file.mtime"].forEach(add)
        return names.map { Property(name: $0, title: base.displayName(of: BaseExpression.propertyID($0))) }
    }

    /// 値の候補。選択肢があればその順、なければ対象のノートにある値
    static func values(of name: String, base: BaseFile, notes: [NoteRecord], types: [String: PropertyType]) -> [String] {
        let id = BaseExpression.propertyID(name)
        if let options = base.schemas[id]?.options, !options.isEmpty { return options.map(\.value) }
        var found = Set<String>()
        for note in targets(base: base, notes: notes, types: types) {
            if id == "file.folder" { found.insert(note.folder); continue }
            switch note.properties[String(id.dropFirst(5))] {
            case .scalar(let text)? where !text.isEmpty: found.insert(text)
            case .list(let items)?: found.formUnion(items.filter { !$0.isEmpty })
            default: break
            }
        }
        return Array(found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(200))
    }

    /// 全体のフィルタに合うノート
    private static func targets(base: BaseFile, notes: [NoteRecord], types: [String: PropertyType]) -> [NoteRecord] {
        guard let filter = base.filter else { return notes }
        return notes.filter { (try? filter.matches(NoteContext(note: $0, types: types, schemas: base.schemas))) == true }
    }
}

// MARK: - クロージャで受ける部品

private final class ClosureButton: NSButton {
    private let onPress: () -> Void

    init(image: NSImage, action: @escaping () -> Void) {
        onPress = action
        super.init(frame: .zero)
        self.image = image
        target = self
        self.action = #selector(press)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func press() { onPress() }
}

private final class ClosurePopUp: NSPopUpButton {
    private let onSelect: (Int) -> Void

    init(titles: [String], onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        font = .systemFont(ofSize: 12)
        controlSize = .small
        target = self
        action = #selector(pick)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func pick() { onSelect(indexOfSelectedItem) }
}

/// Return キーか、ほかへ移ったときに確定する
private final class ClosureTextField: NSTextField {
    private let onCommit: (String) -> Void

    init(onCommit: @escaping (String) -> Void) {
        self.onCommit = onCommit
        super.init(frame: .zero)
        cell?.sendsActionOnEndEditing = true
        controlSize = .small
        target = self
        action = #selector(commit)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func commit() { onCommit(stringValue) }
}

/// 候補から選ぶか、打って Return キーかほかへ移ったときに確定する
private final class ClosureComboBox: NSComboBox, NSComboBoxDelegate {
    private let onCommit: (String) -> Void

    init(onCommit: @escaping (String) -> Void) {
        self.onCommit = onCommit
        super.init(frame: .zero)
        cell?.sendsActionOnEndEditing = true
        controlSize = .small
        completes = true
        numberOfVisibleItems = 12
        delegate = self
        target = self
        action = #selector(commit)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func commit() { onCommit(stringValue) }

    /// 候補を選んだ時点では stringValue がまだ前の値なので、選んだ項目から読む
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard indexOfSelectedItem >= 0, let value = itemObjectValue(at: indexOfSelectedItem) as? String else { return }
        onCommit(value)
    }
}
