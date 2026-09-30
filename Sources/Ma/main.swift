import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let vault = Vault()
    private let sidebar = SidebarViewController()
    private let editor = EditorAreaViewController()
    private var window: NSWindow!
    private var sidebarCollapsedObservation: NSKeyValueObservation?
    private static let sidebarCollapsedKey = "sidebarCollapsed"

    /// ファイルを渡されて起動したときは didFinishLaunching より先に open が呼ばれるので、画面はここで作る
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        let editorItem = NSSplitViewItem(viewController: editor)
        // タイトルバーの下にタブを並べるので、タイトルバーと本文の区切り線は出さない
        for item in [sidebarItem, editorItem] {
            item.titlebarSeparatorStyle = .none
            split.addSplitViewItem(item)
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        split.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        window.contentViewController = split
        window.contentMinSize = NSSize(width: 720, height: 480)
        // contentViewController を設定するとビューの最小サイズまで縮むので、設定後にサイズを戻す
        window.setContentSize(NSSize(width: 1100, height: 720))
        split.splitView.setPosition(260, ofDividerAt: 0)
        // 閉じたサイドバーは次回の起動でも閉じたままにする
        sidebarItem.isCollapsed = AppDefaults.shared.bool(forKey: Self.sidebarCollapsedKey)
        editor.tabBar.showsSidebarButton = sidebarItem.isCollapsed
        // メニュー・ボタン・⌃⌘S のどれで開閉しても記録し、タブバーの開くボタンを出し入れする
        sidebarCollapsedObservation = sidebarItem.observe(\.isCollapsed, options: .new) { [editor] _, change in
            let collapsed = change.newValue ?? false
            MainActor.assumeIsolated {
                AppDefaults.shared.set(collapsed, forKey: Self.sidebarCollapsedKey)
                editor.tabBar.showsSidebarButton = collapsed
            }
        }
        window.center()
        window.setFrameAutosaveName("main")
        window.title = "Ma"
        window.titlebarSeparatorStyle = .none
        // タイトルバーの帯と文字は出さず、信号機ボタンだけ本文の上に重ねる（タイトルは Mission Control やウィンドウメニューで使われる）
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        sidebar.onSelect = { [vault] url, newTab in vault.open(url, newTab: newTab) }
        editor.onChange = { [vault] url, text in vault.textDidChange(text, url: url) }
        editor.onOpenLink = { [unowned self] target, newTab in openLink(target, newTab: newTab) }
        editor.propertyTypes = { [vault] in vault.propertyTypes }
        editor.loadNotes = { [vault] in await vault.noteRecords() }
        editor.propertySchemas = { [vault] url, text in vault.propertySchemas(for: url, text: text) }
        editor.onOpenNote = { [vault] url, newTab in vault.open(url, newTab: newTab) }
        editor.onSetProperty = { [vault, editor] url, key, value, type in
            // 開いているノートはエディタで書き換え（取り消せる）、開いていなければファイルを書き換える
            if !editor.setProperty(in: url, key, to: value, type: type) {
                vault.setProperty(in: url, key, to: value, type: type)
            }
            vault.saveNow()
        }
        editor.onRenameProperty = { [vault, editor] urls, key, newKey in
            // 保存を待っている編集を先に書き、ファイルを直接書き換えた分を古い本文で上書きしないようにする
            vault.saveNow()
            for url in urls where editor.renameProperty(in: url, from: key, to: newKey) == nil {
                vault.renameProperty(in: url, from: key, to: newKey)
            }
            // 型が決めてあれば、新しい名前にも同じ型を付ける（ほかのノートが古い名前を使っているかもしれないので、古い方は残す）
            if let types = vault.propertyTypes, let type = types.recorded[key], types.recorded[newKey] == nil {
                types.set(type, for: newKey)
            }
            vault.saveNow()
        }
        editor.tabBar.onSelect = { [vault] index in vault.selectTab(at: index) }
        editor.tabBar.onClose = { [vault] index in vault.closeTab(at: index) }
        editor.tabBar.onMove = { [vault] source, destination in vault.moveTab(from: source, to: destination) }
        editor.tabBar.onNewTab = { [vault] in vault.newTab() }
        editor.tabBar.onBack = { [vault] in vault.goBack() }
        editor.tabBar.onForward = { [vault] in vault.goForward() }
        editor.tabBar.onToggleSidebar = { [split] in split.toggleSidebar(nil) }
        vault.viewState = { [unowned self] tab in editor.viewState(of: tab) }
        vault.onTreeChange = { [unowned self] in
            sidebar.reload(vault.tree)
            sidebar.select(vault.activeTab.url)
            editor.notesDidChange()
        }
        sidebar.onOpenBookmark = { [unowned self] bookmark, newTab in openBookmark(bookmark, newTab: newTab) }
        sidebar.onToggleBookmark = { [vault] url in vault.toggleBookmark(url) }
        sidebar.onRemoveBookmark = { [vault] indexPath in vault.removeBookmark(at: indexPath) }
        sidebar.isBookmarked = { [vault] url in vault.isBookmarked(url) }
        sidebar.onDelete = { [unowned self] url in delete(url) }
        vault.onBookmarksChange = { [unowned self] in
            sidebar.reload(bookmarks: vault.bookmarks)
            updateNoteHeader()
        }
        editor.onToggleFavorite = { [unowned self] in toggleBookmark(nil) }
        sidebar.calendarView.onSelectDate = { [vault] date in vault.openDailyNote(for: date) }
        vault.onNotesChange = { [unowned self] in
            let calendar = sidebar.calendarView
            calendar.firstWeekday = vault.dailyNotes?.settings.firstWeekday ?? Calendar.current.firstWeekday
            calendar.hasNote = vault.dailyNotes.map { notes in { notes.exists(for: $0) } }
        }
        vault.onLoad = { [unowned self] tab, document in editor.show(document, in: tab) }
        vault.resolveSaveConflict = { url in
            let alert = NSAlert()
            alert.messageText = "ファイルが外部で変更されています"
            alert.informativeText = "「\(url.lastPathComponent)」には Ma の未保存の編集もあります。残す内容を選んでください。"
            alert.addButton(withTitle: "外部の変更を読み込む")
            alert.addButton(withTitle: "Ma の内容で上書き")
            return alert.runModal() == .alertSecondButtonReturn
        }
        vault.onExternalChange = { [unowned self] in
            editor.notesDidChange()
            updateNoteHeader()
        }
        vault.onTabsChange = { [unowned self] in
            editor.update(tabs: vault.tabs, activeIndex: vault.activeIndex,
                          canGoBack: vault.canGoBack, canGoForward: vault.canGoForward)
            let url = vault.activeTab.url
            sidebar.select(url)
            sidebar.calendarView.selectedDate = url.flatMap { vault.dailyNotes?.date(of: $0) }
            window.title = url?.deletingPathExtension().lastPathComponent ?? "Ma"
            window.subtitle = vault.root?.lastPathComponent ?? ""
            updateNoteHeader()
        }
    }

    private func updateNoteHeader() {
        editor.setFavorite(vault.activeTab.url.map { vault.isBookmarked($0) })
        // `.base` の表は左上にビューの切り替えがあるので、パスはノートのときだけ出す
        let url = vault.activeTab.url.flatMap { $0.pathExtension.lowercased() == "base" ? nil : $0 }
        editor.setNotePath(url.flatMap { vault.relativePath(of: $0) })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if vault.root == nil { vault.restoreLastRoot() }
        window.makeKeyAndOrderFront(nil)
        keepTrafficLightsPlaced()
        // マウスの戻る・進むボタン
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [vault] event in
            let button = event.buttonNumber
            guard button == 3 || button == 4 else { return event }
            MainActor.assumeIsolated { button == 3 ? vault.goBack() : vault.goForward() }
            return nil
        }
        // Obsidian などで変えたノート・プロパティ型・ブックマークを反映する
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [vault] _ in MainActor.assumeIsolated { vault.refreshExternalChanges() }
        }

        // `swift run` で起動したとき（.app の外）も通常のアプリとして前面に出す。
        // .app は LaunchServices が前面に出すので、ここで activate するとバックグラウンド起動（open -g）でも前面に出てしまう
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    /// `open -a Ma ノート.md` や Finder からファイルを渡されたとき
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "md" }) else { return }
        if let root = vault.root, url.path.hasPrefix(root.path + "/") {
            vault.open(url, newTab: true)
        } else {
            vault.setRoot(url.deletingLastPathComponent(), remember: false)
            vault.open(url)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// 信号機ボタンを `TrafficLights` の位置に置く。AppKit はタイトルの変更やサイドバーの開閉のたびに
    /// タイトルバーを並べ直して元の位置に戻すので、ボタンの位置が変わったら置き直す
    private func keepTrafficLightsPlaced() {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(trafficLightFrameDidChange(_:)), name: NSView.frameDidChangeNotification, object: button
            )
        }
        placeTrafficLights()
    }

    /// AppKit が3つのボタンを順に並べ直している途中で呼ばれるので、並べ終わってから置き直す
    /// （その場で動かすと、後から並べられる緑のボタンが元の位置に戻った）
    @objc private func trafficLightFrameDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [self] in placeTrafficLights() }
    }

    /// フルスクリーンではメニューバーと一緒に出るので動かさない
    private func placeTrafficLights() {
        guard !window.styleMask.contains(.fullScreen) else { return }
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type), let superview = button.superview else { continue }
            let top = TrafficLights.centerY - button.frame.height / 2
            let origin = NSPoint(
                x: TrafficLights.leading + CGFloat(index) * TrafficLights.spacing,
                y: superview.isFlipped ? top : superview.bounds.height - top - button.frame.height
            )
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        // サイドバーを閉じているとき、タブは緑のボタンの右から並ぶので描き直す
        editor.tabBar.needsDisplay = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        vault.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// `[[ノート名]]` は vault のノートを開き、`[表示名](URL)` は既定のブラウザなど URL に対応するアプリで開く。
    /// スキームのない URL は、開いているノートからの相対パスのノートとして扱う
    private func openLink(_ target: LinkTarget, newTab: Bool) {
        switch target {
        case .note(let name):
            guard let url = vault.noteURL(forLink: name) else { return }
            vault.open(url, newTab: newTab)
        case .url(let string):
            if let url = URL(string: string), url.scheme != nil {
                NSWorkspace.shared.open(url)
            } else if let path = string.removingPercentEncoding, let current = vault.activeTab.url {
                let url = current.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
                if url.pathExtension.lowercased() == "md", FileManager.default.fileExists(atPath: url.path) {
                    vault.open(url, newTab: newTab)
                }
            }
        }
    }

    /// サイドバーから削除する。Obsidian で確認をオンにしていれば先に尋ねる
    private func delete(_ url: URL) {
        if vault.promptsDelete {
            let alert = NSAlert()
            alert.messageText = "「\(url.deletingPathExtension().lastPathComponent)」を削除しますか？"
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { alert.informativeText = "フォルダの中のファイルもすべて削除します。" }
            alert.addButton(withTitle: "削除")
            alert.addButton(withTitle: "キャンセル")
            alert.buttons[0].hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try vault.deleteItem(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Ma で開けないファイル（画像や PDF など）は Obsidian で開く。Obsidian がなければ既定のアプリに任せる
    private func openBookmark(_ bookmark: Bookmark, newTab: Bool) {
        guard let url = bookmark.url else { return }
        switch bookmark.kind {
        case .file:
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            if ["md", "base"].contains(url.pathExtension.lowercased()) {
                vault.open(url, newTab: newTab)
            } else if let obsidian = Self.obsidianURL(for: url), NSWorkspace.shared.urlForApplication(toOpen: obsidian) != nil {
                NSWorkspace.shared.open(obsidian)
            } else {
                NSWorkspace.shared.open(url)
            }
        case .folder:
            sidebar.reveal(folder: url)
        case .url:
            NSWorkspace.shared.open(url)
        case .group, .other:
            break
        }
    }

    private static func obsidianURL(for file: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: file.path)]
        return components.url
    }

    @objc func toggleBookmark(_ sender: Any?) {
        guard let url = vault.activeTab.url else { return }
        vault.toggleBookmark(url)
    }

    @objc func goBack(_ sender: Any?) { vault.goBack() }
    @objc func goForward(_ sender: Any?) { vault.goForward() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(goBack(_:)) { return vault.canGoBack }
        if menuItem.action == #selector(goForward(_:)) { return vault.canGoForward }
        guard menuItem.action == #selector(toggleBookmark(_:)) else { return true }
        guard let url = vault.activeTab.url else {
            menuItem.title = "お気に入りに追加"
            return false
        }
        menuItem.title = vault.isBookmarked(url) ? "お気に入りから外す" : "お気に入りに追加"
        return true
    }

    @objc func openFolder(_ sender: Any?) { vault.chooseFolder() }
    @objc func showFileSearch(_ sender: Any?) { sidebar.focusSearch() }
    @objc func save(_ sender: Any?) { vault.saveNow() }
    @objc func newTab(_ sender: Any?) { vault.newTab() }
    /// 何も開いていないタブが1つだけなら、ウィンドウを閉じる
    @objc func closeTab(_ sender: Any?) {
        if vault.tabs.count == 1, vault.activeTab.url == nil {
            window.performClose(sender)
        } else {
            vault.closeTab(at: vault.activeIndex)
        }
    }
    @objc func selectNextTab(_ sender: Any?) { vault.selectTab(at: (vault.activeIndex + 1) % vault.tabs.count) }
    @objc func selectPreviousTab(_ sender: Any?) {
        vault.selectTab(at: (vault.activeIndex + vault.tabs.count - 1) % vault.tabs.count)
    }
    /// ⌘1〜⌘8 はその番号のタブ、⌘9 は右端のタブ
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        vault.selectTab(at: sender.tag == 9 ? vault.tabs.count - 1 : sender.tag - 1)
    }
    @objc func openTodayNote(_ sender: Any?) {
        vault.openDailyNote(for: Date())
        sidebar.calendarView.show(month: Date())
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Ma を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Ma")

        let file = NSMenu(title: "ファイル")
        file.addItem(withTitle: "新規タブ", action: #selector(newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "フォルダを開く…", action: #selector(openFolder(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "ファイルを検索", action: #selector(showFileSearch(_:)), keyEquivalent: "p")
        file.addItem(withTitle: "保存", action: #selector(save(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "今日のデイリーノート", action: #selector(openTodayNote(_:)), keyEquivalent: "d")
        file.addItem(withTitle: "お気に入りに追加", action: #selector(toggleBookmark(_:)), keyEquivalent: "B")
        file.addItem(.separator())
        file.addItem(withTitle: "タブを閉じる", action: #selector(closeTab(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "ウインドウを閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        main.addItem(submenu: file, title: "ファイル")

        let edit = NSMenu(title: "編集")
        edit.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "プロパティを追加", action: #selector(EditorAreaViewController.addProperty(_:)), keyEquivalent: ";")
        edit.addItem(withTitle: "コメントを追加…", action: #selector(EditorAreaViewController.addAIComment(_:)), keyEquivalent: "M")
        edit.addItem(.separator())
        let find = edit.addItem(withTitle: "検索…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        main.addItem(submenu: edit, title: "編集")

        let view = NSMenu(title: "表示")
        view.addItem(withTitle: "ソース表示", action: #selector(EditorAreaViewController.toggleSourceMode(_:)), keyEquivalent: "e")
        view.addItem(withTitle: "コールアウトのアイコン", action: #selector(EditorAreaViewController.toggleCalloutIcons(_:)), keyEquivalent: "")
        let toggle = view.addItem(withTitle: "サイドバーを切り替え", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        view.addItem(withTitle: "戻る", action: #selector(goBack(_:)), keyEquivalent: "[")
        view.addItem(withTitle: "進む", action: #selector(goForward(_:)), keyEquivalent: "]")
        main.addItem(submenu: view, title: "表示")

        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "次のタブを表示", action: #selector(selectNextTab(_:)), keyEquivalent: "}")
        windowMenu.addItem(withTitle: "前のタブを表示", action: #selector(selectPreviousTab(_:)), keyEquivalent: "{")
        let nextTab = windowMenu.addItem(withTitle: "次のタブを表示", action: #selector(selectNextTab(_:)), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = .control
        nextTab.isHidden = true
        nextTab.allowsKeyEquivalentWhenHidden = true
        let previousTab = windowMenu.addItem(withTitle: "前のタブを表示", action: #selector(selectPreviousTab(_:)), keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        previousTab.isHidden = true
        previousTab.allowsKeyEquivalentWhenHidden = true
        for number in 1...9 {
            let item = windowMenu.addItem(withTitle: number == 9 ? "最後のタブを表示" : "タブ \(number) を表示",
                                          action: #selector(selectTabByNumber(_:)), keyEquivalent: "\(number)")
            item.tag = number
        }
        main.addItem(submenu: windowMenu, title: "ウインドウ")
        NSApp.windowsMenu = windowMenu

        return main
    }
}

/// 信号機ボタンの位置。サイドバーのボタンやタブの文字と縦を揃え、窓の左上の角から離す
enum TrafficLights {
    /// ボタンの中心の、ウィンドウの上端からの高さ
    static let centerY: CGFloat = 20
    /// 閉じるボタンの左端（macOS の既定は 9）
    static let leading: CGFloat = 14
    /// ボタンどうしの左端の間隔（macOS の既定と同じ）
    static let spacing: CGFloat = 20
    /// 緑のボタンの右端
    static let trailing: CGFloat = leading + spacing * 2 + 14
    /// サイドバー上端のボタン（ファイル・お気に入り・開閉）の左端と、1つの幅
    static let sidebarButtonsLeading: CGFloat = trailing + 15
    static let sidebarButtonWidth: CGFloat = 26
    /// 一覧の切り替えボタンと開閉ボタンの間
    static let sidebarToggleGap: CGFloat = 12
    /// サイドバーの開閉ボタンの左端と幅。サイドバーを閉じたときもタブバーの同じ位置に出して、開閉でアイコンが動かないようにする
    static let sidebarToggleLeading: CGFloat = sidebarButtonsLeading + sidebarButtonWidth * 2 + 4 + sidebarToggleGap
    static let sidebarToggleWidth: CGFloat = sidebarButtonWidth
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
