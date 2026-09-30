import AppKit

/// `.base` を開いたタブ。ビューを切り替えて、条件に合うノートを表で見せる（いまは見るだけ）
final class BaseViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// vault のノートを読み直す
    var loadNotes: () async -> [NoteRecord] = { [] }
    var propertyTypes: () -> [String: PropertyType] = { [:] }
    var onOpenNote: ((URL, _ newTab: Bool) -> Void)?

    private enum Row {
        case group(BaseValue, property: String, count: Int)
        case note(NoteRecord)
    }

    private(set) var url: URL?
    private var base: BaseFile?
    private var notes: [NoteRecord] = []
    private var rows: [Row] = []
    private var selectedView = 0

    private let viewPicker = NSSegmentedControl()
    private let countLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let tableView = NSTableView()
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
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.gridColor = .separatorColor.withAlphaComponent(0.4)
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 30
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clickRow(_:))
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

    private func rebuild() {
        guard let base, base.views.indices.contains(selectedView) else {
            return showMessage("ビューがありません")
        }
        let view = base.views[selectedView]
        guard view.type == "table" else {
            return showMessage("このビューの種類（\(view.type)）はまだ表示できません")
        }
        let groups: [BaseFile.Group]
        do {
            groups = try base.evaluate(view, notes: notes, types: propertyTypes())
        } catch {
            return showMessage("フィルタを評価できません: \(error)")
        }
        messageLabel.isHidden = true
        scrollView.isHidden = false
        let total = groups.reduce(0) { $0 + $1.notes.count }
        countLabel.stringValue = "\(total) 件"
        // 列を足すと表は今の行数のままセルを作ろうとするので、列を作り直すあいだは行を空にしておく
        rows = []
        tableView.reloadData()
        setColumns(view, base: base)
        rows = groups.flatMap { group -> [Row] in
            guard let value = group.value, let groupBy = view.groupBy else { return group.notes.map(Row.note) }
            return [.group(value, property: groupBy.property, count: group.notes.count)] + group.notes.map(Row.note)
        }
        tableView.reloadData()
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

    // MARK: - 表

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .group = rows[row] { return false }
        return true
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
            let stack = NSStackView(views: [title, field])
            stack.spacing = 8
            if let chips = title as? ChipsView {
                chips.widthAnchor.constraint(equalToConstant: chips.chips.reduce(0) { $0 + Self.chipWidth($1) }).isActive = true
                chips.heightAnchor.constraint(equalToConstant: 24).isActive = true
            }
            content = stack
        case .note(let note):
            guard let property = tableColumn?.identifier.rawValue else { return nil }
            let value = NoteContext(note: note, types: propertyTypes(), schemas: schemas).value(of: property)
            if property == "file.name" || property == "file.basename" {
                field.stringValue = note.basename
                field.textColor = .linkColor
                content = field
            } else if let schema = schemas[property] {
                let chips = ChipsView()
                chips.chips = schema.chips(for: value)
                chips.heightAnchor.constraint(equalToConstant: 24).isActive = true
                content = chips
            } else {
                field.stringValue = value.text
                content = field
            }
        }
        let cell = NSTableCellView()
        cell.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if content is ChipsView {
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8).isActive = true
        }
        return cell
    }

    private static func chipWidth(_ chip: ChipsView.Chip) -> CGFloat {
        ceil(NSAttributedString(string: chip.label, attributes: [.font: ChipsView.font]).size().width) + 18
    }

    /// ノートの名前の列をクリックしたらノートを開く（⌘クリックは新しいタブ）
    @objc private func clickRow(_ sender: Any?) {
        let row = tableView.clickedRow, column = tableView.clickedColumn
        guard rows.indices.contains(row), tableView.tableColumns.indices.contains(column),
              case .note(let note) = rows[row],
              ["file.name", "file.basename"].contains(tableView.tableColumns[column].identifier.rawValue)
        else { return }
        onOpenNote?(note.url, NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }
}
