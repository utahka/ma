import AppKit

/// vault 内のノートと `.base` を名前・パスで絞り込み、キーボードから開くための小さなパネル
@MainActor
final class QuickOpenPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private struct Item {
        let url: URL
        let path: String
    }

    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    private let search = NSSearchField()
    private let table = NSTableView()
    private var allItems: [Item] = []
    private var items: [Item] = []
    private var onOpen: ((URL, Bool) -> Void)?

    override init() {
        super.init()
        panel.title = "ファイルを検索"
        panel.isReleasedWhenClosed = false

        search.placeholderString = "ファイル名またはパス"
        search.delegate = self
        // 既定では入力の途中でも action が送られ、打ちかけの語で開いてしまう。確定は Return だけで行う
        search.sendsWholeSearchString = true

        let column = NSTableColumn(identifier: .init("path"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .default
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        // クリックしても検索欄からフォーカスを動かさず、キー操作（Esc など）を検索欄で受け続ける
        table.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let content = NSView()
        panel.contentView = content
        for view in [search, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    func show(files: [URL], root: URL, from window: NSWindow, onOpen: @escaping (URL, Bool) -> Void) {
        allItems = files.map { url in
            Item(url: url, path: String(url.path.dropFirst(root.path.count + 1)).precomposedStringWithCanonicalMapping)
        }
        self.onOpen = onOpen
        search.stringValue = ""
        filter()
        if panel.sheetParent == nil { window.beginSheet(panel) }
        panel.makeFirstResponder(search)
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    /// 検索欄にフォーカスを置いたまま、↑↓ で候補を選び、Return で開き、Esc で閉じる
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)): openSelected(nil)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(table.selectedRow + offset, 0), items.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func close() {
        if let parent = panel.sheetParent { parent.endSheet(panel) }
        onOpen = nil
    }

    private func filter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased()
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        items = allItems.filter { item in
            let path = item.path.lowercased()
            return words.allSatisfy(path.contains)
        }.sorted { lhs, rhs in
            let leftName = lhs.url.deletingPathExtension().lastPathComponent.lowercased()
            let rightName = rhs.url.deletingPathExtension().lastPathComponent.lowercased()
            let leftPrefix = !query.isEmpty && leftName.hasPrefix(query)
            let rightPrefix = !query.isEmpty && rightName.hasPrefix(query)
            if leftPrefix != rightPrefix { return leftPrefix }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        table.reloadData()
        if !items.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("path")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = items[row].path
        return cell
    }

    @objc private func openSelected(_ sender: Any?) {
        let row = table.selectedRow >= 0 ? table.selectedRow : 0
        guard items.indices.contains(row) else { return }
        let item = items[row]
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        let onOpen = onOpen
        close()
        onOpen?(item.url, newTab)
    }
}
