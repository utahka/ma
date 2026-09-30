import AppKit

/// お気に入りの行。読み直すたびに作り直す
private final class BookmarkNode {
    let bookmark: Bookmark
    let children: [BookmarkNode]

    init(_ bookmark: Bookmark) {
        self.bookmark = bookmark
        if case .group(let children) = bookmark.kind { self.children = children.map(BookmarkNode.init) } else { children = [] }
    }
}

/// ファイル検索の結果の行。vault からの相対パスはフォルダ名を添えて同名のノートを見分けるのに使う
private final class SearchResult {
    let node: FileNode
    let path: String

    init(node: FileNode, path: String) {
        self.node = node
        self.path = path
    }
}

/// 上部のボタンで切り替える、ファイルツリーとお気に入りの一覧。その上に検索欄、下にカレンダー。
/// ノートを選ぶと `onSelect` を呼ぶ（⌘クリックは新しいタブ）
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    NSSearchFieldDelegate {
    enum Mode: String {
        case files
        case bookmarks
    }

    var onSelect: ((URL, _ newTab: Bool) -> Void)?
    var onOpenBookmark: ((Bookmark, _ newTab: Bool) -> Void)?
    /// 右クリックメニューから、ノートかフォルダをお気に入りに加える・外す
    var onToggleBookmark: ((URL) -> Void)?
    var onRemoveBookmark: (([Int]) -> Void)?
    var isBookmarked: ((URL) -> Bool)?
    /// 右クリックメニューから、ノートかフォルダを削除する
    var onDelete: ((URL) -> Void)?
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
    /// 検索欄に文字があるあいだは、一覧の代わりに名前・パスで絞り込んだファイルを平らに並べる
    private let searchField = NSSearchField()
    private let searchView = NSOutlineView()
    private var searchScrollView: NSScrollView!
    private var searchResults: [SearchResult] = []
    private var isSearching: Bool { !searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }
    private let emptyBookmarksLabel = NSTextField(wrappingLabelWithString: "お気に入りはありません。右クリックか ⌘⇧B で追加できます")
    private var tree: [FileNode] = []
    private var bookmarkNodes: [BookmarkNode] = []
    /// 選択中のタブのノート。読み直した後に選択行を戻すのに使う
    private var currentURL: URL?

    override func loadView() {
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 4
        for (mode, symbol, label) in [(Mode.files, "folder", "ファイル"), (.bookmarks, "star", "お気に入り")] {
            let button = NSButton(image: Self.centeredSymbol(symbol, label: label), target: self, action: #selector(modeButtonClicked(_:)))
            // 選んでいる一覧は枠ではなく色で示す
            button.isBordered = false
            button.refusesFirstResponder = true
            button.widthAnchor.constraint(equalToConstant: TrafficLights.sidebarButtonWidth).isActive = true
            button.toolTip = label
            button.tag = mode == .files ? 0 : 1
            modeButtons[mode] = button
            buttons.addArrangedSubview(button)
        }
        // 一覧の切り替えとは役割が違うので、サイドバーの右端に置く
        let toggle = NSButton(image: Self.centeredSymbol("sidebar.left", label: "サイドバーを閉じる"),
                              target: self, action: #selector(toggleSidebarClicked(_:)))
        toggle.isBordered = false
        toggle.refusesFirstResponder = true
        toggle.contentTintColor = .secondaryLabelColor
        toggle.widthAnchor.constraint(equalToConstant: TrafficLights.sidebarToggleWidth).isActive = true
        toggle.toolTip = "サイドバーを閉じる"

        func makeList(_ outlineView: NSOutlineView) -> NSScrollView {
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
            // タイトルバーの下から置くので、タイトルバーの分の余白は要らない
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.documentView = outlineView
            return scrollView
        }
        for (mode, outlineView) in [(Mode.files, filesView), (.bookmarks, bookmarksView)] {
            let menu = NSMenu()
            menu.delegate = self
            outlineView.menu = menu
            scrollViews[mode] = makeList(outlineView)
        }
        searchScrollView = makeList(searchView)
        searchScrollView.isHidden = true

        searchField.placeholderString = "ファイルを検索"
        searchField.delegate = self
        // 既定では入力の途中でも action が送られる。開くのは Return と行のクリックだけにする
        searchField.sendsWholeSearchString = true

        emptyBookmarksLabel.textColor = .secondaryLabelColor
        emptyBookmarksLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyBookmarksLabel.alignment = .center

        let separator = NSBox()
        separator.boxType = .separator

        let container = NSView()
        let lists = (Array(scrollViews.values) + [searchScrollView]).map { $0 as NSView }
        for view in [buttons, toggle, searchField, separator, calendarView, emptyBookmarksLabel] + lists {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        // ファイルツリーとカレンダーを窓の縁から離す余白
        let padding: CGFloat = 10
        var constraints = [
            // 信号機ボタンの右に、タブの文字と同じ高さで並べる（上に余白を取る）
            buttons.centerYAnchor.constraint(equalTo: container.topAnchor, constant: TrafficLights.centerY),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: TrafficLights.sidebarButtonsLeading),
            // 開閉ボタンは同じ高さで右端に置き、サイドバーの幅を変えても右端に付いていく
            toggle.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -TrafficLights.sidebarToggleTrailing),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: TabBarView.height + 4),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            calendarView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: padding / 2),
            calendarView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            calendarView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            calendarView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            calendarView.heightAnchor.constraint(equalToConstant: CalendarView.preferredHeight),
            emptyBookmarksLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: padding * 2),
            emptyBookmarksLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding * 2),
            emptyBookmarksLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding * 2),
        ]
        for scrollView in Array(scrollViews.values) + [searchScrollView!] {
            constraints += [
                scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
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
    /// 枠と絵の中心のずれがアイコンごとに違い、フォルダとお気に入りで 1pt 高さがずれたので、
    /// 枠を持たない画像に描き直して絵の中心を信号機ボタンの中心に揃える
    static func centeredSymbol(_ name: String, label: String) -> NSImage {
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
        for (key, button) in modeButtons {
            button.contentTintColor = key == mode ? .controlAccentColor : .secondaryLabelColor
        }
        updateVisibleList()
        select(currentURL)
    }

    /// 検索中は検索結果を、それ以外は選んでいる一覧を出す
    private func updateVisibleList() {
        for (key, scrollView) in scrollViews { scrollView.isHidden = isSearching || key != mode }
        searchScrollView.isHidden = !isSearching
        updateEmptyLabel()
    }

    // MARK: - 検索

    /// ⌘P。サイドバーを閉じていれば開き、検索欄に入力できるようにする
    func focusSearch() {
        if let item = (parent as? NSSplitViewController)?.splitViewItem(for: self), item.isCollapsed {
            item.isCollapsed = false
        }
        view.window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ obj: Notification) { updateSearch() }

    /// 検索欄にフォーカスを置いたまま、↑↓ で候補を選び、Return で開き（⌘Return は新しいタブ）、Esc で検索をやめる
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSearchSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): moveSearchSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            let row = searchView.selectedRow
            guard searchResults.indices.contains(row) else { return true }
            onSelect?(searchResults[row].node.url, NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        case #selector(NSResponder.cancelOperation(_:)):
            if isSearching {
                searchField.stringValue = ""
                updateSearch()
            } else {
                view.window?.makeFirstResponder(nil)
            }
        default: return false
        }
        return true
    }

    private func moveSearchSelection(by offset: Int) {
        guard !searchResults.isEmpty else { return }
        let row = min(max(searchView.selectedRow + offset, 0), searchResults.count - 1)
        selectSearchRow(row)
    }

    /// 矢印キーで選んでいる間はノートを開かない
    private func selectSearchRow(_ row: Int) {
        isSyncingSelection = true
        searchView.selectRowIndexes([row], byExtendingSelection: false)
        isSyncingSelection = false
        searchView.scrollRowToVisible(row)
    }

    /// 空白で区切った語をすべてパスに含むファイルを、名前がその語で始まるもの、パス順の順に並べる
    private func updateSearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
            .precomposedStringWithCanonicalMapping.lowercased()
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var results: [SearchResult] = []
        func collect(_ nodes: [FileNode], prefix: String) {
            for node in nodes {
                let path = prefix + node.url.lastPathComponent.precomposedStringWithCanonicalMapping
                if node.isDirectory {
                    collect(node.children, prefix: path + "/")
                } else if !words.isEmpty, words.allSatisfy(path.lowercased().contains) {
                    results.append(SearchResult(node: node, path: path))
                }
            }
        }
        collect(tree, prefix: "")
        searchResults = results.sorted { lhs, rhs in
            let leftPrefix = lhs.node.name.lowercased().hasPrefix(query)
            let rightPrefix = rhs.node.name.lowercased().hasPrefix(query)
            if leftPrefix != rightPrefix { return leftPrefix }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        isSyncingSelection = true
        searchView.reloadData()
        isSyncingSelection = false
        if !searchResults.isEmpty { selectSearchRow(0) }
        updateVisibleList()
    }

    /// 応答チェーンに任せると、ウィンドウがキーでないときに NSSplitViewController まで届かないので、親に直接送る
    @objc private func toggleSidebarClicked(_ sender: NSButton) {
        (parent as? NSSplitViewController)?.toggleSidebar(sender)
    }

    @objc private func modeButtonClicked(_ sender: NSButton) {
        show(sender.tag == 0 ? .files : .bookmarks)
    }

    private func updateEmptyLabel() {
        emptyBookmarksLabel.isHidden = isSearching || mode != .bookmarks || !bookmarkNodes.isEmpty
    }

    func reload(_ tree: [FileNode]) {
        self.tree = tree
        reloadData(of: filesView)
        if isSearching { updateSearch() }
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

    /// お気に入りしたフォルダを選んだとき、ファイルの一覧に切り替えてそのフォルダを開いて見せる
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

    /// その行で開くノート（フォルダやお気に入りのグループは nil）
    private func noteURL(ofRow row: Int, in outlineView: NSOutlineView) -> URL? {
        guard row >= 0 else { return nil }
        switch outlineView.item(atRow: row) {
        case let node as FileNode: return node.isDirectory ? nil : node.url
        case let result as SearchResult: return result.node.url
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
        case let result as SearchResult: onSelect?(result.node.url, true)
        case let node as BookmarkNode: onOpenBookmark?(node.bookmark, true)
        default: break
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case let node as BookmarkNode: node.children.count
        case let node as FileNode: node.children.count
        case is SearchResult: 0
        default: outlineView === searchView ? searchResults.count : outlineView === bookmarksView ? bookmarkNodes.count : tree.count
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case let node as BookmarkNode: node.children[index]
        case let node as FileNode: node.children[index]
        default:
            if outlineView === searchView { searchResults[index] }
            else if outlineView === bookmarksView { bookmarkNodes[index] }
            else { tree[index] }
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
        cell.toolTip = nil
        switch item {
        case let node as FileNode:
            cell.textField?.stringValue = node.name
            symbol = node.isDirectory ? "folder" : node.isBase ? "tablecells" : "doc.text"
        case let result as SearchResult:
            // 名前の後ろにフォルダを薄く添える
            let text = NSMutableAttributedString(string: result.node.name)
            let folder = (result.path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                text.append(NSAttributedString(string: "  " + folder, attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                ]))
            }
            cell.textField?.attributedStringValue = text
            cell.toolTip = result.path
            symbol = result.node.isBase ? "tablecells" : "doc.text"
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
            case .group: symbol = "star.square.on.square"
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
        case let result as SearchResult:
            onSelect?(result.node.url, false)
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
            let title = isBookmarked?(node.url) == true ? "お気に入りから外す" : "お気に入りに追加"
            let item = menu.addItem(withTitle: title, action: #selector(toggleBookmark(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = node.url
            menu.addItem(.separator())
            let delete = menu.addItem(withTitle: "削除", action: #selector(deleteItem(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = node.url
        case let node as BookmarkNode:
            let item = menu.addItem(withTitle: "お気に入りから外す", action: #selector(removeBookmark(_:)), keyEquivalent: "")
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

    @objc private func deleteItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onDelete?(url)
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
