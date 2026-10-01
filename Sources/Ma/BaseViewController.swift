import AppKit

/// `.base` を開いたタブ。ビューを切り替えて、条件に合うノートを表かカード（`type: cards`）で見せる
final class BaseViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// vault のノートを読み直す
    var loadNotes: () async -> [NoteRecord] = { [] }
    var propertyTypes: () -> [String: PropertyType] = { [:] }
    var onOpenNote: ((URL, _ newTab: Bool) -> Void)?
    /// セルで値を変えたとき。ノートへの書き込みは呼び出し側が受け持つ
    var onSetProperty: ((URL, String, PropertyValue, PropertyType) -> Void)?
    /// プロパティ名を変えたとき（書き換えるノート、古い名前、新しい名前）。ノートへの書き込みは呼び出し側が受け持つ
    var onRenameProperty: (([URL], String, String) -> Void)?
    /// 列を足したときに、Obsidian の型を `.obsidian/types.json` に記録する
    var onSetPropertyType: ((String, PropertyType) -> Void)?

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
    /// 出しているシートの NSAlert（名前の変更の入力と確認）
    private var presentedAlert: NSAlert?

    private let viewPicker = NSSegmentedControl()
    /// グループ化するプロパティと向きを選ぶボタン（Notion のビューの上の控えめなボタンにならう）
    private let groupButton = NSButton(title: "", target: nil, action: nil)
    private let sortEditor = BaseSortEditor()
    private let propertiesEditor = BasePropertiesEditor()
    private let countLabel = NSTextField(labelWithString: "")
    private let filterButton = NSButton()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let tableView = BaseTableView()
    private lazy var headerView = tableView.headerView
    private let scrollView = NSScrollView()
    private let cardsView = BaseCardsView()

    private static let font = NSFont.systemFont(ofSize: 13)

    override func loadView() {
        viewPicker.segmentStyle = .rounded
        viewPicker.trackingMode = .selectOne
        viewPicker.target = self
        viewPicker.action = #selector(pickView(_:))
        groupButton.isBordered = false
        groupButton.imagePosition = .imageLeading
        groupButton.contentTintColor = .secondaryLabelColor
        groupButton.font = .systemFont(ofSize: 12)
        groupButton.target = self
        groupButton.action = #selector(showGroupMenu(_:))
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true
        filterButton.title = "フィルタ"
        filterButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)
        filterButton.imagePosition = .imageLeading
        filterButton.isBordered = false
        filterButton.font = .systemFont(ofSize: 12)
        filterButton.contentTintColor = .secondaryLabelColor
        filterButton.target = self
        filterButton.action = #selector(showFilter(_:))

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
        tableView.onMiddleClick = { [weak self] row, column in
            guard let self, self.rows.indices.contains(row), self.tableView.tableColumns.indices.contains(column),
                  case .note(let note) = self.rows[row],
                  ["file.name", "file.basename"].contains(self.tableView.tableColumns[column].identifier.rawValue)
            else { return }
            self.onOpenNote?(note.url, true)
        }
        tableView.doubleAction = #selector(doubleClickRow(_:))
        // グループの行は Notion と同じく、表と一緒に流す
        tableView.floatsGroupRows = false
        tableView.isHeaderRow = { [weak self] row in
            guard let self, self.rows.indices.contains(row), case .header = self.rows[row] else { return false }
            return true
        }
        // 列の見出し（表の上の見出しと、グループごとの見出しの行）の右クリックメニュー
        let header = BaseHeaderView(frame: tableView.headerView?.frame ?? .zero)
        tableView.headerView = header
        header.menuForColumn = { [weak self] column in self?.columnMenu(at: column) }
        tableView.menuForHeaderColumn = { [weak self] column in self?.columnMenu(at: column) }
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        cardsView.isHidden = true
        cardsView.onOpenNote = { [weak self] note, newTab in self?.onOpenNote?(note.url, newTab) }
        cardsView.onCommit = { [weak self] note, key, value, type in self?.commit(note, key, value, type: type) }
        cardsView.onToggleGroup = { [weak self] value in self?.toggleGroup(value) }

        let container = NSView()
        sortEditor.onChange = { [weak self] sort in self?.saveSort(sort) }
        propertiesEditor.onChange = { [weak self] order in self?.saveVisibleColumns(order) }
        for view in [viewPicker, groupButton, countLabel, messageLabel, scrollView, cardsView, sortEditor.button, filterButton, propertiesEditor.button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            viewPicker.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            viewPicker.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            groupButton.centerYAnchor.constraint(equalTo: viewPicker.centerYAnchor),
            groupButton.leadingAnchor.constraint(equalTo: viewPicker.trailingAnchor, constant: 12),
            countLabel.centerYAnchor.constraint(equalTo: viewPicker.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: groupButton.trailingAnchor, constant: 12),
            sortEditor.button.centerYAnchor.constraint(equalTo: viewPicker.centerYAnchor),
            // 右端はタブ全体の☆ボタンが重なるので、その左に置く
            sortEditor.button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -56),
            filterButton.centerYAnchor.constraint(equalTo: viewPicker.centerYAnchor),
            filterButton.trailingAnchor.constraint(equalTo: sortEditor.button.leadingAnchor, constant: -12),
            propertiesEditor.button.centerYAnchor.constraint(equalTo: viewPicker.centerYAnchor),
            propertiesEditor.button.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -12),
            messageLabel.topAnchor.constraint(equalTo: viewPicker.bottomAnchor, constant: 16),
            messageLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: viewPicker.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            cardsView.topAnchor.constraint(equalTo: viewPicker.bottomAnchor, constant: 12),
            cardsView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            cardsView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cardsView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
        guard cardsView.isHidden else { return }
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
        let isCards = view.type == "cards"
        guard view.type == "table" || isCards else {
            return showMessage("このビューの種類（\(view.type)）はまだ表示できません")
        }
        do {
            groups = try base.evaluate(view, notes: notes, types: propertyTypes())
        } catch {
            return showMessage("フィルタを評価できません: \(error)")
        }
        messageLabel.isHidden = true
        scrollView.isHidden = isCards
        cardsView.isHidden = !isCards
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
        sortEditor.update(sort: view.sort, candidates: sortCandidates(view, base: base))
        propertiesEditor.update(visible: view.order.isEmpty ? ["file.name"] : view.order,
                                candidates: propertyCandidates(view, base: base))
        let total = groups.reduce(0) { $0 + $1.notes.count }
        countLabel.stringValue = "\(total) 件"
        if isCards {
            let awaiting = groups.flatMap(\.notes).filter {
                BaseCardsView.isAwaiting($0, layout: cardLayout(view, base: base), types: types)
            }.count
            if awaiting > 0 { countLabel.stringValue += "・返事待ち \(awaiting) 件" }
            updateGroupButton(view, base: base)
            loadCollapsed()
            return layOutRows()
        }
        // 列を足すと表は今の行数のままセルを作ろうとするので、列を作り直すあいだは行を空にしておく
        rows = []
        tableView.reloadData()
        setColumns(view, base: base)
        // グループに分けるときは、表の上の見出しの代わりにグループごとに列名を出す
        // 最初に開いたビューがグループ分けでも、外す前の見出しを退避する（三項演算子の中だと nil にしたあとで読んでしまう）
        let header = headerView
        tableView.headerView = view.groupBy == nil ? header : nil
        updateGroupButton(view, base: base)
        loadCollapsed()
        layOutRows()
    }

    /// グループと開閉の状態から行を並べ直す
    private func layOutRows() {
        guard let base, base.views.indices.contains(selectedView) else { return }
        let groupBy = base.views[selectedView].groupBy
        if base.views[selectedView].type == "cards" {
            rows = []
            tableView.reloadData()
            return showCards(base.views[selectedView], base: base)
        }
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
        cardsView.isHidden = true
    }

    // MARK: - カード

    /// カードの上部と下部に出すプロパティ。下部はビューの `ma:` の `body`、なければ `order` のうち型のない文字列（テキスト）のプロパティ。
    /// 返事の欄は `ma:` の `reply`、なければ下部が2つ以上あるときの最後のもの（`[相談, 返事]` の返事）
    private func cardLayout(_ view: BaseFile.View, base: BaseFile) -> BaseCardsView.Layout {
        let order = view.order.isEmpty ? ["file.name"] : view.order
        let types = propertyTypes()
        let body = view.cardBody ?? order.filter { property in
            guard let key = Self.noteKey(property), base.schemas[property] == nil, dateColumns[property] == nil else { return false }
            return types[key] == nil || types[key] == .text
        }
        let top = order.filter { !body.contains($0) && $0 != "file.name" && $0 != "file.basename" }
        let reply = view.cardReply ?? (body.count >= 2 ? body.last : nil)
        return BaseCardsView.Layout(top: top, body: body, reply: reply)
    }

    private func showCards(_ view: BaseFile.View, base: BaseFile) {
        cardsView.show(BaseCardsView.Content(
            groups: groups, groupBy: view.groupBy?.property, collapsed: collapsed,
            layout: cardLayout(view, base: base), schemas: base.schemas, types: propertyTypes(),
            dateColumns: dateColumns, displayName: { base.displayName(of: $0) }
        ))
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
        // 右端の「＋」の列（Notion の表と同じく、ここからプロパティを足す）。`.base` の order には書かない
        let add = NSTableColumn(identifier: BaseTableView.addColumnID)
        add.title = "＋"
        add.headerCell.alignment = .center
        add.headerCell.font = .systemFont(ofSize: 14)
        add.width = 36
        add.minWidth = 36
        add.resizingMask = []
        add.headerToolTip = "プロパティを追加"
        tableView.addTableColumn(add)
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
        let ids = tableView.tableColumns.map(\.identifier).filter { $0 != BaseTableView.addColumnID }.map(\.rawValue)
        let raw = Dictionary(zip(view.order, view.rawOrder), uniquingKeysWith: { first, _ in first })
        let order = ids.map { raw[$0] ?? $0 }
        var sizes: [String: Int] = [:]
        for column in tableView.tableColumns where column.identifier != BaseTableView.addColumnID {
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

    // MARK: - 表示する列

    /// 表に出せるプロパティ。今の列、`properties:` に定義のあるもの、対象ノートのフロントマターのキー、ファイルの属性の順
    private func propertyCandidates(_ view: BaseFile.View, base: BaseFile) -> [BasePropertiesEditor.Candidate] {
        var seen = Set<String>()
        var ids: [String] = []
        func add(_ id: String) { if seen.insert(id).inserted { ids.append(id) } }
        view.order.forEach(add)
        let types = propertyTypes()
        let targets = notes.filter { base.contains($0, types: types) } + groups.flatMap(\.notes)
        let others = Set(base.schemas.keys).union(base.displayNames.keys.filter { $0.hasPrefix("note.") })
            .union(targets.flatMap { $0.properties.keys.map { "note." + $0 } })
        others.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.forEach(add)
        ["file.name", "file.path", "file.folder", "file.ext", "file.ctime", "file.mtime", "file.size"].forEach(add)
        return ids.map { BasePropertiesEditor.Candidate(property: $0, title: base.displayName(of: $0)) }
    }

    /// 表に出す列（列の ID を表示順に並べたもの）を、そのビューの `order` に書く。
    /// 隠した列の幅（`columnSize`）は残す（Obsidian も残す）
    private func saveVisibleColumns(_ ids: [String]) {
        guard let url, let base, base.views.indices.contains(selectedView), !ids.isEmpty else { return }
        let view = base.views[selectedView]
        let raw = Dictionary(zip(view.order, view.rawOrder), uniquingKeysWith: { first, _ in first })
        let order = ids.map { raw[$0] ?? BaseFile.rawName($0) }
        guard order != view.rawOrder else { return }
        // 列の幅の保存を待っていたら先に書く（あとから古い列の並びで書き戻さないように）
        if saveColumnsTask != nil {
            saveColumnsTask?.cancel()
            saveColumnsTask = nil
            saveColumns()
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let updated = BaseFile.updatingColumns(text, view: selectedView, order: order, columnSize: [:]) else {
                return NSLog("表示するプロパティを保存できません（.base の形が想定と違います）: \(url.path)")
            }
            if updated != text { try updated.write(to: url, atomically: true, encoding: .utf8) }
            self.base = try BaseFile(yaml: updated)
        } catch {
            NSLog("表示するプロパティの保存に失敗: \(url.path): \(error)")
        }
        rebuild()
    }

    private func hideColumn(_ property: String) {
        let ids = tableView.tableColumns.map(\.identifier).filter { $0 != BaseTableView.addColumnID }.map(\.rawValue).filter { $0 != property }
        saveVisibleColumns(ids)
    }

    // MARK: - 列の見出しのメニュー

    /// 列の見出しの右クリックメニュー。列ごとの操作はここに項目を足す
    private func columnMenu(at column: Int) -> NSMenu? {
        guard tableView.tableColumns.indices.contains(column),
              tableView.tableColumns[column].identifier != BaseTableView.addColumnID else { return nil }
        let property = tableView.tableColumns[column].identifier.rawValue
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, symbol: String, enabled: Bool = true, action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("列を隠す", symbol: "eye.slash", enabled: tableView.tableColumns.count > 2) { [weak self] in
            self?.hideColumn(property)
        }
        // ファイルの属性（file.*）や式（formula.*）はノートのプロパティではないので名前を変えられない
        add("名前を変更…", symbol: "pencil", enabled: Self.noteKey(property) != nil) { [weak self] in
            self?.renameProperty(property)
        }
        menu.addItem(.separator())
        // ファイルの属性（file.*）などノートのプロパティでない列は消せない
        add("プロパティを削除…", symbol: "trash", enabled: Self.noteKey(property) != nil) { [weak self] in
            self?.deleteProperty(property)
        }
        return menu
    }

    // MARK: - プロパティ名の変更

    /// 新しい名前を聞き、対象ノートのフロントマターのキーと、この `.base` の中の参照を書き換える
    private func renameProperty(_ property: String) {
        guard let url, let base, let old = Self.noteKey(property), let window = view.window else { return }
        let prompt = NSAlert()
        prompt.messageText = "プロパティ名を変更"
        prompt.informativeText = "「\(old)」の新しい名前を入力してください。"
        prompt.addButton(withTitle: "次へ")
        prompt.addButton(withTitle: "キャンセル")
        let field = NSTextField(string: old)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        prompt.accessoryView = field
        prompt.window.initialFirstResponder = field
        present(prompt, in: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let new = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard new != old else { return }
            // シートを閉じ終えてから次のシートを出す
            DispatchQueue.main.async { self?.confirmRename(from: old, to: new, url: url, base: base) }
        }
    }

    /// シートで出す。NSAlert は自分で持っていないと、出したまま解放されてシートが勝手に閉じる
    private func present(_ alert: NSAlert, in window: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        presentedAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            if self?.presentedAlert === alert { self?.presentedAlert = nil }
            completion(response)
        }
    }

    private func confirmRename(from old: String, to new: String, url: URL, base: BaseFile) {
        guard let window = view.window else { return }
        func fail(_ message: String) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "「\(old)」の名前を変更できません"
            alert.informativeText = message
            present(alert, in: window) { _ in }
        }
        let text: String, updated: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            updated = try BaseFile.renamingProperty(text, from: old, to: new)
        } catch {
            return fail("\(error)")
        }
        let types = propertyTypes()
        let targets = notes.filter { $0.properties[old] != nil && base.contains($0, types: types) }
        // 新しい名前のキーがすでにあるノートは、値を上書きしないように書き換えない
        let conflicts = targets.filter { $0.properties[new] != nil }
        let writes = targets.filter { $0.properties[new] == nil }
        var lines = [writes.isEmpty
            ? "書き換えるノートはありません。"
            : "\(writes.count) 件のノートのフロントマターを書き換えます。値はそのままです。"]
        if !conflicts.isEmpty {
            let names = conflicts.prefix(5).map { "・" + $0.basename }.joined(separator: "\n")
            lines.append("次の \(conflicts.count) 件はすでに「\(new)」があるため、上書きせずにそのまま残します。\n" + names
                + (conflicts.count > 5 ? "\n…" : ""))
        }
        if updated != text { lines.append("この .base の列・並べ替え・グループ・フィルタの参照も新しい名前にします。") }
        let alert = NSAlert()
        alert.messageText = "プロパティ名を「\(old)」から「\(new)」に変更しますか？"
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        present(alert, in: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performRename(from: old, to: new, url: url, text: text, updated: updated, notes: writes.map(\.url))
        }
    }

    private func performRename(from old: String, to new: String, url: URL, text: String, updated: String, notes targets: [URL]) {
        // 列の幅の保存を待っていたら先に書く（あとから古い名前で書き戻さないように）
        if saveColumnsTask != nil {
            saveColumnsTask?.cancel()
            saveColumnsTask = nil
            saveColumns()
        }
        do {
            // 確認のあいだに .base が変わっていたら、今の中身で書き換え直す
            let current = try String(contentsOf: url, encoding: .utf8)
            let result = current == text ? updated : try BaseFile.renamingProperty(current, from: old, to: new)
            if result != current { try result.write(to: url, atomically: true, encoding: .utf8) }
            base = try BaseFile(yaml: result)
        } catch {
            NSLog("プロパティ名の変更で .base を保存できません: \(url.path): \(error)")
            return showMessage(".base を保存できません: \(error)")
        }
        onRenameProperty?(targets, old, new)
        reload()
    }

    /// 「＋」の列は右端から動かさない
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        let last = tableView.numberOfColumns - 1
        return columnIndex != last && newColumnIndex != last
    }

    /// 表の上の見出しの「＋」を押したとき（グループに分けないビュー）
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard tableColumn.identifier == BaseTableView.addColumnID, let header = tableView.headerView,
              let index = tableView.tableColumns.firstIndex(of: tableColumn) else { return }
        showPropertyAdder(relativeTo: header.headerRect(ofColumn: index), of: header)
    }

    // MARK: - プロパティの追加

    private func showPropertyAdder(relativeTo rect: NSRect, of view: NSView) {
        guard let base else { return }
        let adder = BasePropertyAdder()
        adder.existing = { [weak self] name in
            guard let self, let id = self.existingProperty(named: name, base: base) else { return nil }
            return base.displayName(of: id)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = adder
        adder.onAdd = { [weak self, weak popover] name, kind in
            popover?.close()
            self?.addProperty(named: name, kind: kind)
        }
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    /// 名前が既存のプロパティ（`.base` に定義がある・表示名が同じ・types.json に型がある・どれかのノートにある）なら、その列の ID
    private func existingProperty(named name: String, base: BaseFile) -> String? {
        if let id = base.displayNames.first(where: { $0.value == name })?.key { return id }
        let id = BaseExpression.propertyID(name)
        if id.hasPrefix("file.") || base.schemas[id] != nil || base.displayNames[id] != nil { return id }
        guard let key = Self.noteKey(id) else { return nil }
        if propertyTypes()[key] != nil || notes.contains(where: { $0.properties[key] != nil }) { return id }
        return nil
    }

    /// そのビューの `order` の末尾に列を足す。新しいプロパティなら、型を `.base` の `properties:`（Ma の型）か
    /// `.obsidian/types.json`（Obsidian の型）に書く。ノートには書かない（値を入れたときに書く）
    private func addProperty(named name: String, kind: BasePropertyAdder.Kind) {
        // 列の幅の保存を待っていたら先に書く（あとから古い列の並びで書き戻さないように）
        if saveColumnsTask != nil {
            saveColumnsTask?.cancel()
            saveColumnsTask = nil
            saveColumns()
        }
        guard let url, let base, base.views.indices.contains(selectedView) else { return }
        let view = base.views[selectedView]
        let existing = existingProperty(named: name, base: base)
        let id = existing ?? BaseExpression.propertyID(name)
        let order = view.order.isEmpty ? ["file.name"] : view.order
        guard !order.contains(id) else {
            // もう列にあるなら、その列を見せるだけにする
            if let index = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) { tableView.scrollColumnToVisible(index) }
            return
        }
        let rawOrder = view.order.isEmpty ? ["file.name"] : view.rawOrder
        do {
            var text = try String(contentsOf: url, encoding: .utf8)
            if existing == nil, let schemaKind = kind.schemaKind {
                guard let updated = BaseFile.addingProperty(text, id: id, kind: schemaKind) else {
                    return showError("プロパティを追加できません", ".base の書き方が想定と違うため、ファイルを変更しませんでした。")
                }
                text = updated
            }
            guard let updated = BaseFile.updatingColumns(text, view: selectedView, order: rawOrder + [BaseFile.rawName(id)], columnSize: [:]) else {
                return showError("プロパティを追加できません", ".base の書き方が想定と違うため、ファイルを変更しませんでした。")
            }
            try updated.write(to: url, atomically: true, encoding: .utf8)
            self.base = try BaseFile(yaml: updated)
        } catch {
            return showError("プロパティを追加できません", "\(error)")
        }
        if existing == nil, let type = kind.obsidianType, let key = Self.noteKey(id) { onSetPropertyType?(key, type) }
        rebuild()
        if let index = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) { tableView.scrollColumnToVisible(index) }
    }

    // MARK: - グループ化の設定

    private func updateGroupButton(_ view: BaseFile.View, base: BaseFile) {
        groupButton.title = view.groupBy.map { "グループ: " + base.displayName(of: $0.property) } ?? "グループ"
        let image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        groupButton.image = image?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    }

    /// 「グループなし」、グループにできるプロパティ（表の列と、`ma:` で型を決めたプロパティ）、昇順・降順
    @objc private func showGroupMenu(_ sender: NSButton) {
        guard let base, base.views.indices.contains(selectedView) else { return }
        let view = base.views[selectedView]
        let menu = NSMenu()
        let none = NSMenuItem(title: "グループなし", action: #selector(pickGroupProperty(_:)), keyEquivalent: "")
        none.target = self
        none.state = view.groupBy == nil ? .on : .off
        menu.addItem(none)
        menu.addItem(.separator())
        var properties = view.order.isEmpty ? ["file.name"] : view.order
        for property in base.schemas.keys.sorted() + [view.groupBy?.property].compactMap({ $0 }) where !properties.contains(property) {
            properties.append(property)
        }
        for property in properties {
            let item = NSMenuItem(title: base.displayName(of: property), action: #selector(pickGroupProperty(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = property
            item.image = NSImage(systemSymbolName: symbolName(of: property), accessibilityDescription: nil)
            item.state = view.groupBy?.property == property ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, ascending) in [("昇順", true), ("降順", false)] {
            let item = NSMenuItem(title: title, action: view.groupBy == nil ? nil : #selector(pickGroupDirection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ascending
            item.state = view.groupBy?.ascending == ascending ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func pickGroupProperty(_ sender: NSMenuItem) {
        guard let base, base.views.indices.contains(selectedView) else { return }
        let view = base.views[selectedView]
        guard let property = sender.representedObject as? String else { return saveGroupBy(nil) }
        // 列にあるプロパティは `.base` の order と同じ書き方（`種別` など）で書く
        let raw = Dictionary(zip(view.order, view.rawOrder), uniquingKeysWith: { first, _ in first })
        saveGroupBy((raw[property] ?? property, view.groupBy?.ascending ?? true))
    }

    @objc private func pickGroupDirection(_ sender: NSMenuItem) {
        guard let base, base.views.indices.contains(selectedView),
              let groupBy = base.views[selectedView].groupBy, let ascending = sender.representedObject as? Bool else { return }
        let view = base.views[selectedView]
        let raw = Dictionary(zip(view.order, view.rawOrder), uniquingKeysWith: { first, _ in first })
        saveGroupBy((raw[groupBy.property] ?? groupBy.property, ascending))
    }

    /// そのビューの `groupBy` を `.base` に書き、表を作り直す
    private func saveGroupBy(_ groupBy: (property: String, ascending: Bool)?) {
        guard let url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let updated = BaseFile.updatingGroupBy(text, view: selectedView, groupBy: groupBy) else {
                return NSLog("グループ化を保存できません（.base の形が想定と違います）: \(url.path)")
            }
            if updated != text { try updated.write(to: url, atomically: true, encoding: .utf8) }
            base = try BaseFile(yaml: updated)
        } catch {
            NSLog("グループ化の保存に失敗: \(url.path): \(error)")
        }
        rebuild()
    }

    // MARK: - ソートの保存

    /// 並べ替えに選べるプロパティ。表の列を先に、ビューに出ているノートのほかのプロパティとファイルの属性を後ろに並べる
    private func sortCandidates(_ view: BaseFile.View, base: BaseFile) -> [BaseSortEditor.Candidate] {
        var seen = Set<String>()
        var ids: [String] = []
        func add(_ id: String) { if seen.insert(id).inserted { ids.append(id) } }
        view.order.forEach(add)
        view.sort.map(\.property).forEach(add)
        let others = Set(base.schemas.keys).union(base.displayNames.keys.filter { $0.hasPrefix("note.") })
            .union(groups.flatMap(\.notes).flatMap { $0.properties.keys.map { "note." + $0 } })
        others.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.forEach(add)
        ["file.name", "file.ctime", "file.mtime", "file.size", "file.path"].forEach(add)
        return ids.map { BaseSortEditor.Candidate(property: $0, title: base.displayName(of: $0)) }
    }

    /// 並べ替えの条件を `.base` のそのビューの `sort` に書き、表を並べ直す
    private func saveSort(_ sort: [BaseFile.Sort]) {
        guard let url, base?.views.indices.contains(selectedView) == true else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let updated = BaseFile.updatingSort(text, view: selectedView, sort: sort) else {
                return NSLog("並べ替えを保存できません（.base の形が想定と違います）: \(url.path)")
            }
            if updated != text { try updated.write(to: url, atomically: true, encoding: .utf8) }
            base = try BaseFile(yaml: updated)
            rebuild()
        } catch {
            NSLog("並べ替えの保存に失敗: \(url.path): \(error)")
        }
    }

    // MARK: - フィルタの設定

    @objc private func showFilter(_ sender: NSButton) {
        guard let url, let base, base.views.indices.contains(selectedView) else { return }
        let filter: BaseFilterNode?
        do {
            filter = try BaseFilterNode.viewFilter(in: String(contentsOf: url, encoding: .utf8), view: selectedView)
        } catch {
            return showMessage("フィルタを読めません: \(error)")
        }
        let (notes, types) = (notes, propertyTypes())
        let editor = BaseFilterEditor(
            filter: filter,
            properties: BaseFilterEditor.properties(base: base, view: base.views[selectedView], notes: notes, types: types),
            values: { BaseFilterEditor.values(of: $0, base: base, notes: notes, types: types) }
        )
        let view = selectedView
        editor.onChange = { [weak self] filter in self?.saveFilter(filter, view: view) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// そのビューの `filters:` の行だけを書き換えて、表を作り直す
    private func saveFilter(_ filter: BaseFilterNode?, view: Int) {
        guard let url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let updated = BaseFile.updatingFilter(text, view: view, filter: filter) else {
                return NSLog("フィルタを保存できません（.base の形が想定と違います）: \(url.path)")
            }
            if updated != text { try updated.write(to: url, atomically: true, encoding: .utf8) }
            base = try BaseFile(yaml: updated)
            rebuild()
        } catch {
            showMessage("フィルタを保存できません: \(error)")
        }
    }

    // MARK: - プロパティの削除

    /// `.base` からプロパティの定義と参照を消す。ノートの値は残す。フィルタで使っていれば消さずに知らせる
    private func deleteProperty(_ property: String) {
        guard Self.noteKey(property) != nil, let base, let window = view.window else { return }
        let name = base.displayName(of: property)
        let alert = NSAlert()
        alert.messageText = "プロパティ「\(name)」を削除しますか？"
        var info = "この .base からプロパティの定義（表示名・型）と、すべてのビューの列・並べ替え・グループ化での指定を消します。ノートの値は残ります。"
        let uses = base.filterUses(of: property)
        if !uses.isEmpty {
            info += "\n\nこのプロパティはフィルタ（\(uses.joined(separator: "、"))）で使われています。フィルタの条件は書き換えずに残します。"
        }
        alert.informativeText = info
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        alert.buttons[0].hasDestructiveAction = true
        present(alert, in: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.removeProperty(property)
        }
    }

    private func removeProperty(_ property: String) {
        guard let url else { return }
        // 列の幅の保存を待っていたら先に書く（あとから消した列を含む並びで書き戻さないように）
        if saveColumnsTask != nil {
            saveColumnsTask?.cancel()
            saveColumnsTask = nil
            saveColumns()
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let updated = BaseFile.removingProperty(text, property: property) else {
                return showError("プロパティを削除できません", ".base の書き方が想定と違うため、ファイルを変更しませんでした。")
            }
            if updated != text { try updated.write(to: url, atomically: true, encoding: .utf8) }
            base = try BaseFile(yaml: updated)
            rebuild()
        } catch {
            showError("プロパティを削除できません", "\(error)")
        }
    }

    private func showError(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        if let window = view.window { present(alert, in: window) { _ in } } else { alert.runModal() }
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
            if tableColumn?.identifier == BaseTableView.addColumnID {
                let image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil) ?? NSImage()
                let button = ClosureButton(image: image.withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) ?? image) {}
                button.onPress = { [weak self, weak button] in
                    guard let button else { return }
                    self?.showPropertyAdder(relativeTo: button.bounds, of: button)
                }
                button.contentTintColor = .secondaryLabelColor
                button.toolTip = "プロパティを追加"
                button.setAccessibilityLabel("プロパティを追加")
                content = button
                break
            }
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
            guard let property = tableColumn?.identifier.rawValue, tableColumn?.identifier != BaseTableView.addColumnID else { return nil }
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
    var onPress: () -> Void

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

/// 押したらクロージャを呼ぶメニューの項目
private final class ClosureMenuItem: NSMenuItem {
    private let onSelect: () -> Void

    init(title: String, action: @escaping () -> Void) {
        onSelect = action
        super.init(title: title, action: #selector(select), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func select() { onSelect() }
}

/// 表の上の列の見出し。右クリックした列のメニューを出す
private final class BaseHeaderView: NSTableHeaderView {
    var menuForColumn: (Int) -> NSMenu? = { _ in nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        let column = column(at: convert(event.locationInWindow, from: nil))
        return column >= 0 ? menuForColumn(column) : nil
    }
}

/// グループごとの列の見出しの行で、列の境界のドラッグで幅を、見出しのドラッグで順番を変えられる表
/// （グループに分けたときは表の上の見出しを出さないので、その代わり）
private final class BaseTableView: NSTableView {
    var onMiddleClick: ((Int, Int) -> Void)?

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        onMiddleClick?(row(at: point), column(at: point))
    }

    var isHeaderRow: (Int) -> Bool = { _ in false }
    /// グループごとの列の見出しの行を右クリックしたときのメニュー
    var menuForHeaderColumn: (Int) -> NSMenu? = { _ in nil }
    /// 右端の「＋」の列。幅を変えず、入れ替えもしない
    static let addColumnID = NSUserInterfaceItemIdentifier("ma.addProperty")

    private static let grabWidth: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0, isHeaderRow(row) else { return super.mouseDown(with: event) }
        if let column = resizableColumn(at: point) {
            trackResize(of: tableColumns[column], from: point)
        } else if case let column = self.column(at: point), column >= 0, allowsColumnReordering,
                  tableColumns[column].identifier != Self.addColumnID {
            trackMove(of: column)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        guard row >= 0, isHeaderRow(row), column >= 0 else { return super.menu(for: event) }
        return menuForHeaderColumn(column)
    }

    /// 境界の左の列（右端が point の近くにある列）
    private func resizableColumn(at point: NSPoint) -> Int? {
        tableColumns.indices.first { tableColumns[$0].identifier != Self.addColumnID && abs(rect(ofColumn: $0).maxX - point.x) <= Self.grabWidth }
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
            guard target >= 0, target != current, tableColumns[target].identifier != Self.addColumnID else { continue }
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
            for column in tableColumns.indices where tableColumns[column].identifier != Self.addColumnID {
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
