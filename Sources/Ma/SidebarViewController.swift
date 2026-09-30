import AppKit

/// ブックマークの行。読み直すたびに作り直す
private final class BookmarkNode {
    let bookmark: Bookmark
    let children: [BookmarkNode]

    init(_ bookmark: Bookmark) {
        self.bookmark = bookmark
        if case .group(let children) = bookmark.kind { self.children = children.map(BookmarkNode.init) } else { children = [] }
    }
}

/// 上部のボタンで切り替える、ファイルツリーとブックマークの一覧。その下にカレンダー。
/// ノートを選ぶと `onSelect` を呼ぶ（⌘クリックは新しいタブ）
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    enum Mode: String {
        case files
        case bookmarks
    }

    var onSelect: ((URL, _ newTab: Bool) -> Void)?
    var onOpenBookmark: ((Bookmark, _ newTab: Bool) -> Void)?
    /// 右クリックメニューから、ノートかフォルダをブックマークに加える・外す
    var onToggleBookmark: ((URL) -> Void)?
    var onRemoveBookmark: (([Int]) -> Void)?
    var isBookmarked: ((URL) -> Bool)?
    /// タブの切り替えに合わせて選択行を動かしている間は、ノートを開き直さない
    private var isSyncingSelection = false
    let calendarView = CalendarView()

    /// 表示中の一覧を記録し、次回の起動でも同じ一覧を出す
    private(set) var mode: Mode = AppDefaults.shared.string(forKey: "sidebarMode").flatMap(Mode.init) ?? .files
    /// 一覧ごとに別のビューにして、切り替えてもフォルダの開閉やスクロール位置を残す
    private let filesView = NSOutlineView()
    private let bookmarksView = NSOutlineView()
    private var scrollViews: [Mode: NSScrollView] = [:]
    private var modeButtons: [Mode: NSButton] = [:]
    private let emptyBookmarksLabel = NSTextField(wrappingLabelWithString: "ブックマークはありません。右クリックか ⌘⇧B で追加できます")
    private var tree: [FileNode] = []
    private var bookmarkNodes: [BookmarkNode] = []
    /// 選択中のタブのノート。読み直した後に選択行を戻すのに使う
    private var currentURL: URL?

    override func loadView() {
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 4
        for (mode, symbol, label) in [(Mode.files, "folder", "ファイル"), (.bookmarks, "bookmark", "ブックマーク")] {
            let button = NSButton(image: Self.centeredSymbol(symbol, label: label), target: self, action: #selector(modeButtonClicked(_:)))
            // 選んでいる一覧は枠ではなく色で示す
            button.isBordered = false
            button.refusesFirstResponder = true
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.toolTip = label
            button.tag = mode == .files ? 0 : 1
            modeButtons[mode] = button
            buttons.addArrangedSubview(button)
        }

        for (mode, outlineView) in [(Mode.files, filesView), (.bookmarks, bookmarksView)] {
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
            let menu = NSMenu()
            menu.delegate = self
            outlineView.menu = menu

            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            // タイトルバーの下から置くので、タイトルバーの分の余白は要らない
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.documentView = outlineView
            scrollViews[mode] = scrollView
        }

        emptyBookmarksLabel.textColor = .secondaryLabelColor
        emptyBookmarksLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyBookmarksLabel.alignment = .center

        let separator = NSBox()
        separator.boxType = .separator

        let container = NSView()
        let lists = scrollViews.values.map { $0 as NSView }
        for view in [buttons, separator, calendarView, emptyBookmarksLabel] + lists {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        // ファイルツリーとカレンダーを窓の縁から離す余白
        let padding: CGFloat = 10
        var constraints = [
            // 信号機ボタンの右に、タブの文字と同じ高さで並べる（上に余白を取る）
            buttons.centerYAnchor.constraint(equalTo: container.topAnchor, constant: TrafficLights.centerY),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: TrafficLights.trailing + 15),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            calendarView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: padding / 2),
            calendarView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            calendarView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            calendarView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            calendarView.heightAnchor.constraint(equalToConstant: CalendarView.preferredHeight),
            emptyBookmarksLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: TabBarView.height + padding * 2),
            emptyBookmarksLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding * 2),
            emptyBookmarksLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding * 2),
        ]
        for scrollView in scrollViews.values {
            constraints += [
                scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: TabBarView.height + 4),
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
                separator.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: padding),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        view = container
        show(mode)
    }

    /// SF Symbols の画像は文字に並べるための枠（alignmentRect）を持ち、NSButton はその枠を中央に置く。
    /// 枠と絵の中心のずれがアイコンごとに違い、フォルダとブックマークで 1pt 高さがずれたので、
    /// 枠を持たない画像に描き直して絵の中心を信号機ボタンの中心に揃える
    private static func centeredSymbol(_ name: String, label: String) -> NSImage {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: label)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    func show(_ mode: Mode) {
        self.mode = mode
        AppDefaults.shared.set(mode.rawValue, forKey: "sidebarMode")
        for (key, scrollView) in scrollViews { scrollView.isHidden = key != mode }
        for (key, button) in modeButtons {
            button.contentTintColor = key == mode ? .controlAccentColor : .secondaryLabelColor
        }
        updateEmptyLabel()
        select(currentURL)
    }

    @objc private func modeButtonClicked(_ sender: NSButton) {
        show(sender.tag == 0 ? .files : .bookmarks)
    }

    private func updateEmptyLabel() {
        emptyBookmarksLabel.isHidden = mode != .bookmarks || !bookmarkNodes.isEmpty
    }

    func reload(_ tree: [FileNode]) {
        self.tree = tree
        reloadData(of: filesView)
    }

    func reload(bookmarks: [Bookmark]) {
        bookmarkNodes = bookmarks.map(BookmarkNode.init)
        updateEmptyLabel()
        reloadData(of: bookmarksView)
    }

    private func reloadData(of outlineView: NSOutlineView) {
        isSyncingSelection = true
        outlineView.reloadData()
        isSyncingSelection = false
        select(currentURL)
    }

    /// 選択中のタブのノートの行を、両方の一覧で選ぶ
    func select(_ url: URL?) {
        currentURL = url
        for outlineView in [filesView, bookmarksView] {
            let rows = 0..<outlineView.numberOfRows
            let row = url == nil ? nil : rows.first { noteURL(ofRow: $0, in: outlineView)?.path == url?.path }
            isSyncingSelection = true
            if let row {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            } else {
                outlineView.deselectAll(nil)
            }
            isSyncingSelection = false
        }
    }

    /// ブックマークしたフォルダを選んだとき、ファイルの一覧に切り替えてそのフォルダを開いて見せる
    func reveal(folder url: URL) {
        func path(to nodes: [FileNode]) -> [FileNode]? {
            for node in nodes where node.isDirectory {
                if node.url.path == url.path { return [node] }
                if url.path.hasPrefix(node.url.path + "/"), let rest = path(to: node.children) { return [node] + rest }
            }
            return nil
        }
        guard let nodes = path(to: tree) else { return }
        show(.files)
        for node in nodes { filesView.expandItem(node) }
        let row = filesView.row(forItem: nodes.last)
        if row >= 0 { filesView.scrollRowToVisible(row) }
        select(currentURL)
    }

    /// その行で開くノート（フォルダやブックマークのグループは nil）
    private func noteURL(ofRow row: Int, in outlineView: NSOutlineView) -> URL? {
        guard row >= 0 else { return nil }
        switch outlineView.item(atRow: row) {
        case let node as FileNode: return node.isDirectory ? nil : node.url
        case let node as BookmarkNode:
            if case .file = node.bookmark.kind { return node.bookmark.url }
            return nil
        default: return nil
        }
    }

    /// ⌘クリックは選択の切り替えになるので、クリックの操作として受けて新しいタブで開く
    @objc private func outlineViewClicked(_ sender: NSOutlineView) {
        guard NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return }
        switch sender.item(atRow: sender.clickedRow) {
        case let node as FileNode where !node.isDirectory: onSelect?(node.url, true)
        case let node as BookmarkNode: onOpenBookmark?(node.bookmark, true)
        default: break
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case let node as BookmarkNode: node.children.count
        case let node as FileNode: node.children.count
        default: outlineView === bookmarksView ? bookmarkNodes.count : tree.count
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case let node as BookmarkNode: node.children[index]
        case let node as FileNode: node.children[index]
        default: outlineView === bookmarksView ? bookmarkNodes[index] : tree[index]
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        switch item {
        case let node as BookmarkNode: !node.children.isEmpty
        case let node as FileNode: node.isDirectory
        default: false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier)
        let symbol: String
        switch item {
        case let node as FileNode:
            cell.textField?.stringValue = node.name
            symbol = node.isDirectory ? "folder" : node.isBase ? "tablecells" : "doc.text"
        case let node as BookmarkNode:
            let bookmark = node.bookmark
            cell.textField?.stringValue = bookmark.displayName
            switch bookmark.kind {
            case .file:
                switch bookmark.url?.pathExtension.lowercased() {
                case "md": symbol = "doc.text"
                case "base": symbol = "tablecells"
                default: symbol = "doc"
                }
            case .folder: symbol = "folder"
            case .url: symbol = "link"
            case .group: symbol = "bookmark"
            case .other: symbol = "questionmark.square.dashed"
            }
        default:
            return nil
        }
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, NSApp.currentEvent?.modifierFlags.contains(.command) != true,
              let outlineView = notification.object as? NSOutlineView else { return }
        switch outlineView.item(atRow: outlineView.selectedRow) {
        case let node as FileNode:
            if node.isDirectory {
                // フォルダは選択ではなく開閉として扱う
                toggleExpansion(node, in: outlineView)
            } else {
                onSelect?(node.url, false)
            }
        case let node as BookmarkNode:
            if case .group = node.bookmark.kind {
                toggleExpansion(node, in: outlineView)
            } else {
                onOpenBookmark?(node.bookmark, false)
            }
            // ノート以外（フォルダ・URL・Obsidian で開くファイル）は選択を開いているノートに戻す
            if noteURL(ofRow: outlineView.selectedRow, in: outlineView)?.path != currentURL?.path { select(currentURL) }
        default:
            break
        }
    }

    private func toggleExpansion(_ item: Any, in outlineView: NSOutlineView) {
        if outlineView.isItemExpanded(item) { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let outlineView = menu === bookmarksView.menu ? bookmarksView : filesView
        switch outlineView.item(atRow: outlineView.clickedRow) {
        case let node as FileNode:
            let title = isBookmarked?(node.url) == true ? "ブックマークから外す" : "ブックマークに追加"
            let item = menu.addItem(withTitle: title, action: #selector(toggleBookmark(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = node.url
        case let node as BookmarkNode:
            let item = menu.addItem(withTitle: "ブックマークから外す", action: #selector(removeBookmark(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = node.bookmark.indexPath
        default:
            break
        }
    }

    @objc private func toggleBookmark(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onToggleBookmark?(url)
    }

    @objc private func removeBookmark(_ sender: NSMenuItem) {
        guard let indexPath = sender.representedObject as? [Int] else { return }
        onRemoveBookmark?(indexPath)
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.textColor = .maText
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
