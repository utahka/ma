import AppKit

/// vault のファイルツリーと、その下のカレンダー。ノートを選ぶと `onSelect` を呼ぶ（⌘クリックは新しいタブ）
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: ((URL, _ newTab: Bool) -> Void)?
    /// タブの切り替えに合わせて選択行を動かしている間は、ノートを開き直さない
    private var isSyncingSelection = false
    let calendarView = CalendarView()

    private let outlineView = NSOutlineView()
    private var tree: [FileNode] = []

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineViewClicked(_:))

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView

        let separator = NSBox()
        separator.boxType = .separator

        let container = NSView()
        for view in [scrollView, separator, calendarView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            calendarView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            calendarView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            calendarView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            calendarView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            calendarView.heightAnchor.constraint(equalToConstant: CalendarView.preferredHeight),
        ])
        view = container
    }

    func reload(_ tree: [FileNode]) {
        self.tree = tree
        outlineView.reloadData()
    }

    /// 選択中のタブのノートの行を選ぶ。閉じたフォルダの中にあるときは選択を外す
    func select(_ url: URL?) {
        let row = (0..<outlineView.numberOfRows).first { (outlineView.item(atRow: $0) as? FileNode)?.url.path == url?.path }
        isSyncingSelection = true
        if let row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        } else {
            outlineView.deselectAll(nil)
        }
        isSyncingSelection = false
    }

    /// ⌘クリックは選択の切り替えになるので、クリックの操作として受けて新しいタブで開く
    @objc private func outlineViewClicked(_ sender: Any?) {
        guard NSApp.currentEvent?.modifierFlags.contains(.command) == true,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? FileNode, !node.isDirectory
        else { return }
        onSelect?(node.url, true)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileNode)?.children.count ?? tree.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FileNode)?.children[index] ?? tree[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier)
        cell.textField?.stringValue = node.name
        cell.imageView?.image = NSImage(
            systemSymbolName: node.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil
        )
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, NSApp.currentEvent?.modifierFlags.contains(.command) != true,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? FileNode else { return }
        if node.isDirectory {
            // フォルダは選択ではなく開閉として扱う
            if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) } else { outlineView.expandItem(node) }
        } else {
            onSelect?(node.url, false)
        }
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        for view in [image, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
