import AppKit

/// 表の右上の「並べ替え」ボタンと、ソートの条件を追加・削除・並べ替えするポップオーバー（Notion のソート設定に倣う）
@MainActor
final class BaseSortEditor: NSObject, NSPopoverDelegate {
    struct Candidate {
        /// 列の ID（`note.ステータス`）
        let property: String
        let title: String
    }

    let button = NSButton()
    /// 条件を変えたとき。`.base` への書き込みは呼び出し側が受け持つ
    var onChange: (([BaseFile.Sort]) -> Void)?

    private var sort: [BaseFile.Sort] = []
    private var candidates: [Candidate] = []
    private var popover: NSPopover?
    private let list = NSStackView()

    override init() {
        super.init()
        button.isBordered = false
        button.refusesFirstResponder = true
        button.imagePosition = .imageLeading
        button.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        button.target = self
        button.action = #selector(togglePopover(_:))
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        update(sort: [], candidates: [])
    }

    /// ビューを切り替えたときや `.base` を読み直したとき
    func update(sort: [BaseFile.Sort], candidates: [Candidate]) {
        self.sort = sort
        // 表示名が重なるもの（`file.name` と `note.name` がどちらも「タスク名」など）は、`.base` での名前を添えて見分ける
        let titles = Dictionary(grouping: candidates, by: \.title)
        self.candidates = candidates.map { candidate in
            guard titles[candidate.title, default: []].count > 1 else { return candidate }
            let name = candidate.property.hasPrefix("note.") ? String(candidate.property.dropFirst(5)) : candidate.property
            return Candidate(property: candidate.property, title: "\(candidate.title)（\(name)）")
        }
        let title = sort.isEmpty ? "並べ替え" : "並べ替え \(sort.count)"
        let color: NSColor = sort.isEmpty ? .secondaryLabelColor : .controlAccentColor
        button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color])
        button.contentTintColor = color
        button.toolTip = sort.isEmpty ? "並べ替えを追加" : sort.map { "\(self.title(of: $0.property)) \($0.ascending ? "昇順" : "降順")" }.joined(separator: " → ")
        if popover?.isShown == true { rebuildList() }
    }

    // MARK: - ポップオーバー

    @objc private func togglePopover(_ sender: NSButton) {
        if let popover, popover.isShown { return popover.performClose(nil) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let controller = NSViewController()
        let container = NSView()
        list.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            list.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            list.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            list.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        controller.view = container
        popover.contentViewController = controller
        self.popover = popover
        rebuildList()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }

    private func rebuildList() {
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, key) in sort.enumerated() { list.addArrangedSubview(row(for: key, at: index)) }
        let unused = candidates.filter { candidate in !sort.contains { $0.property == candidate.property } }
        let add = NSButton(title: "並べ替えを追加", target: self, action: #selector(showAddMenu(_:)))
        add.isBordered = false
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        add.imagePosition = .imageLeading
        add.contentTintColor = .secondaryLabelColor
        add.attributedTitle = NSAttributedString(string: " 並べ替えを追加", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        add.isEnabled = !unused.isEmpty
        var footer: [NSView] = [add]
        if !sort.isEmpty {
            let clear = NSButton(title: "", target: self, action: #selector(removeAll))
            clear.isBordered = false
            clear.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            clear.imagePosition = .imageLeading
            clear.contentTintColor = .secondaryLabelColor
            clear.attributedTitle = NSAttributedString(string: " 並べ替えを削除", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            footer.append(clear)
        }
        let footerStack = NSStackView(views: footer)
        footerStack.orientation = .vertical
        footerStack.alignment = .leading
        footerStack.spacing = 4
        if !sort.isEmpty {
            let separator = NSBox()
            separator.boxType = .separator
            list.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        list.addArrangedSubview(footerStack)
        let width = max(sort.isEmpty ? 200 : 360, list.fittingSize.width + 20)
        popover?.contentSize = NSSize(width: width, height: list.fittingSize.height + 20)
    }

    /// つまみ・プロパティ・向き・削除の1行
    private func row(for key: BaseFile.Sort, at index: Int) -> NSView {
        let grip = SortGrip()
        grip.onDrag = { [weak self] event in self?.trackDrag(from: index, event: event) }

        let property = NSPopUpButton(frame: .zero, pullsDown: false)
        property.controlSize = .small
        property.font = .systemFont(ofSize: 12)
        let used = Set(sort.map(\.property))
        var options = candidates
        if !options.contains(where: { $0.property == key.property }) {
            options.insert(Candidate(property: key.property, title: title(of: key.property)), at: 0)
        }
        property.autoenablesItems = false
        // addItem(withTitle:) は同じ名前の項目を置き換えるので、メニューに直接足す
        for option in options {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.property
            item.isEnabled = option.property == key.property || !used.contains(option.property)
            property.menu?.addItem(item)
        }
        property.selectItem(at: options.firstIndex { $0.property == key.property } ?? 0)
        property.tag = index
        property.target = self
        property.action = #selector(changeProperty(_:))
        property.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true

        let direction = NSPopUpButton(frame: .zero, pullsDown: false)
        direction.controlSize = .small
        direction.font = .systemFont(ofSize: 12)
        direction.addItems(withTitles: ["昇順", "降順"])
        direction.selectItem(at: key.ascending ? 0 : 1)
        direction.tag = index
        direction.target = self
        direction.action = #selector(changeDirection(_:))

        let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "この並べ替えを削除")!
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))!, target: self, action: #selector(removeKey(_:)))
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.tag = index
        remove.toolTip = "この並べ替えを削除"

        let stack = NSStackView(views: [grip, property, direction, remove])
        stack.spacing = 6
        stack.setCustomSpacing(10, after: direction)
        return stack
    }

    private func title(of property: String) -> String {
        candidates.first { $0.property == property }?.title ?? property
    }

    private func commit(_ sort: [BaseFile.Sort]) {
        self.sort = sort
        rebuildList()
        onChange?(sort)
    }

    @objc private func changeProperty(_ sender: NSPopUpButton) {
        guard sort.indices.contains(sender.tag), let property = sender.selectedItem?.representedObject as? String,
              property != sort[sender.tag].property else { return }
        var sort = sort
        sort[sender.tag] = BaseFile.Sort(property: property, ascending: sort[sender.tag].ascending)
        commit(sort)
    }

    @objc private func changeDirection(_ sender: NSPopUpButton) {
        guard sort.indices.contains(sender.tag) else { return }
        let ascending = sender.indexOfSelectedItem == 0
        guard ascending != sort[sender.tag].ascending else { return }
        var sort = sort
        let key = sort[sender.tag]
        sort[sender.tag] = BaseFile.Sort(property: key.property, ascending: ascending, rawProperty: key.rawProperty)
        commit(sort)
    }

    @objc private func removeKey(_ sender: NSButton) {
        guard sort.indices.contains(sender.tag) else { return }
        var sort = sort
        sort.remove(at: sender.tag)
        commit(sort)
    }

    @objc private func removeAll() { commit([]) }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for candidate in candidates where !sort.contains(where: { $0.property == candidate.property }) {
            let item = NSMenuItem(title: candidate.title, action: #selector(addKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.property
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc private func addKey(_ sender: NSMenuItem) {
        guard let property = sender.representedObject as? String else { return }
        commit(sort + [BaseFile.Sort(property: property, ascending: true)])
    }

    /// つまみを掴んだ行を、ポインタのある行の位置へ移していく。離したら書き込む
    private func trackDrag(from start: Int, event: NSEvent) {
        guard let window = list.window else { return }
        let original = sort
        var current = start
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), event.type == .leftMouseDragged {
            let y = list.convert(event.locationInWindow, from: nil).y
            // 行は上から並ぶ。ポインタが乗っている行の番号を探す
            let rows = list.arrangedSubviews.prefix(sort.count)
            guard let target = rows.firstIndex(where: { $0.frame.minY - 3 <= y && y <= $0.frame.maxY + 3 }),
                  target != current else { continue }
            // 行のビューは作り直さずに入れ替える（作り直すと、次のレイアウトまで位置が決まらない）
            let key = sort.remove(at: current)
            sort.insert(key, at: target)
            let moved = list.arrangedSubviews[current]
            list.removeArrangedSubview(moved)
            list.insertArrangedSubview(moved, at: target)
            list.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            current = target
        }
        // 各行のボタンが持つ行番号を振り直す
        rebuildList()
        if sort.map(\.property) != original.map(\.property) { onChange?(sort) }
    }
}

/// 行を並べ替えるつまみ（⋮⋮）
private final class SortGrip: NSImageView {
    var onDrag: ((NSEvent) -> Void)?

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "ドラッグして並べ替え")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        contentTintColor = .tertiaryLabelColor
        toolTip = "ドラッグして並べ替え"
        widthAnchor.constraint(equalToConstant: 16).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onDrag?(event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

// MARK: - ソートの書き戻し

extension BaseFile {
    /// `views` の `index` 番目のビューの `sort` を書き換えた YAML を返す。空なら `sort` のキーごと消す。
    /// `updatingColumns` と同じく YAML 全体は書き直さず、Obsidian が書く形（ブロック形式）を前提に `sort` の行だけを差し替える。
    /// `sort` がなければ `order` の後ろ（なければビューの末尾）に足す。形が想定と違えば nil
    static func updatingSort(_ yaml: String, view index: Int, sort: [Sort]) -> String? {
        var lines = yaml.components(separatedBy: "\n")
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

        guard let viewsLine = lines.firstIndex(of: "views:") else { return nil }
        var items: [Int] = []
        var itemIndent: Int?
        var end = lines.count
        for number in (viewsLine + 1)..<lines.count {
            let line = lines[number]
            if isBlank(line) { continue }
            let depth = indent(line)
            if depth == 0 { end = number; break }
            if line.dropFirst(depth).hasPrefix("- ") {
                if itemIndent == nil { itemIndent = depth }
                if depth == itemIndent { items.append(number) }
            }
        }
        guard let itemIndent, items.indices.contains(index) else { return nil }
        let start = items[index]
        var itemEnd = index + 1 < items.count ? items[index + 1] : end
        while itemEnd > start + 1, isBlank(lines[itemEnd - 1]) { itemEnd -= 1 }
        let keyIndent = itemIndent + 2
        let pad = String(repeating: " ", count: keyIndent)

        func block(_ key: String) -> Range<Int>? {
            guard let keyLine = (start + 1..<itemEnd).first(where: { number in
                indent(lines[number]) == keyIndent && lines[number].dropFirst(keyIndent).hasPrefix(key + ":")
            }) else { return nil }
            var last = keyLine + 1
            while last < itemEnd, isBlank(lines[last]) || indent(lines[last]) > keyIndent
                || (indent(lines[last]) == keyIndent && lines[last].dropFirst(keyIndent).hasPrefix("- ")) {
                last += 1
            }
            return keyLine..<last
        }
        if lines[start].dropFirst(itemIndent + 2).hasPrefix("sort:") { return nil }

        let sortLines = sort.isEmpty ? [] : [pad + "sort:"] + sort.flatMap { key in
            [pad + "  - property: " + scalar(key.rawProperty ?? rawName(key.property)),
             pad + "    direction: " + (key.ascending ? "ASC" : "DESC")]
        }
        if let existing = block("sort") {
            lines.replaceSubrange(existing, with: sortLines)
        } else if !sortLines.isEmpty {
            let at = block("order")?.upperBound ?? itemEnd
            lines.insert(contentsOf: sortLines, at: at)
        }
        return lines.joined(separator: "\n")
    }

    /// 列の ID を `.base` に書く名前にする。Obsidian と同じく、ノートのプロパティは `note.` を付けない
    static func rawName(_ property: String) -> String {
        guard property.hasPrefix("note.") else { return property }
        let name = String(property.dropFirst(5))
        return BaseExpression.propertyID(name) == property ? name : property
    }
}
