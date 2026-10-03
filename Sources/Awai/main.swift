import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
    /// メインウィンドウのタブ。フォルダの状態は分離したウィンドウの `Vault` と共有する
    private let vault = Vault()
    private let sidebar = SidebarViewController()
    private let editor = EditorAreaViewController()
    private var window: NSWindow!
    /// タブをドラッグして分離したウィンドウ
    private var detachedWindows: [DetachedWindow] = []
    private var editorAreas: [EditorAreaViewController] { [editor] + detachedWindows.map(\.editor) }
    /// メニューやキー操作の対象にするタブ。前面にある分離ウィンドウ、なければメインウィンドウ
    private var activeDetached: DetachedWindow? { detachedWindows.first { $0.window.isMainWindow } }
    private var activeVault: Vault { activeDetached?.vault ?? vault }
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

        window = AwaiWindow(
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
        window.title = "Awai"
        window.titlebarSeparatorStyle = .none
        // タイトルバーの帯と文字は出さず、信号機ボタンだけ本文の上に重ねる（タイトルは Mission Control やウィンドウメニューで使われる）
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // AppDelegate が持ち続けるので、閉じたときに解放させない
        window.isReleasedWhenClosed = false
        window.delegate = self

        connect(editor, to: vault, in: window)
        sidebar.onSelect = { [vault] url, newTab in vault.open(url, newTab: newTab) }
        editor.tabBar.onToggleSidebar = { [split] in split.toggleSidebar(nil) }
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
            updateNoteHeader(of: editor, vault: vault)
        }
        sidebar.calendarView.onSelectDate = { [vault] date in vault.openDailyNote(for: date) }
        vault.onNotesChange = { [unowned self] in
            let calendar = sidebar.calendarView
            calendar.firstWeekday = vault.dailyNotes?.settings.firstWeekday ?? Calendar.current.firstWeekday
            calendar.hasNote = vault.dailyNotes.map { notes in { notes.exists(for: $0) } }
        }
    }

    /// メインウィンドウと分離したウィンドウに共通の、エディタ・タブバーと `Vault` の結び付け。
    /// 分離したウィンドウは閉じると捨てるので、クロージャは弱参照で持つ
    private func connect(_ editor: EditorAreaViewController, to vault: Vault, in window: NSWindow) {
        let isMain = vault === self.vault
        editor.onRenameNote = { [weak vault] in
            guard let vault, let url = vault.activeTab.url else { return }
            let alert = NSAlert()
            alert.messageText = "ファイル名を変更"
            alert.informativeText = "フォルダと拡張子はそのままです。ほかのノート内のリンクは変更しません。"
            alert.addButton(withTitle: "変更")
            alert.addButton(withTitle: "キャンセル")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.stringValue = url.deletingPathExtension().lastPathComponent
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do { try vault.renameNote(url, to: field.stringValue) }
            catch {
                let message = NSAlert()
                message.messageText = "名前を変更できませんでした"
                message.informativeText = error.localizedDescription
                message.runModal()
            }
        }
        vault.onDocumentRename = { [weak editor] oldURL, newURL in editor?.renameDocument(from: oldURL, to: newURL) }
        editor.onChange = { [weak vault] url, text in vault?.textDidChange(text, url: url) }
        editor.onOpenLink = { [unowned self, weak vault] target, newTab in
            if let vault { openLink(target, newTab: newTab, in: vault) }
        }
        editor.propertyTypes = { [weak vault] in vault?.propertyTypes }
        editor.wikiLinkPaths = { [weak vault] in vault?.wikiLinkPaths() ?? [] }
        editor.loadNotes = { [weak vault] in await vault?.noteRecords() ?? [] }
        editor.propertySchemas = { [weak vault] url, text in vault?.propertySchemas(for: url, text: text) ?? [:] }
        editor.onOpenNote = { [weak vault] url, newTab in vault?.open(url, newTab: newTab) }
        editor.onSetProperty = { [unowned self, weak vault] url, key, value, type in
            guard let vault else { return }
            // 開いているノートはエディタで書き換え（取り消せる）、開いていなければファイルを書き換える。ほかのウィンドウで開いていることもある
            if !editorAreas.contains(where: { $0.setProperty(in: url, key, to: value, type: type) }) {
                vault.setProperty(in: url, key, to: value, type: type)
            }
            vault.saveNow()
        }
        editor.onRenameProperty = { [unowned self, weak vault] urls, key, newKey in
            guard let vault else { return }
            // 保存を待っている編集を先に書き、ファイルを直接書き換えた分を古い本文で上書きしないようにする
            vault.saveNow()
            for url in urls where !editorAreas.contains(where: { $0.renameProperty(in: url, from: key, to: newKey) != nil }) {
                vault.renameProperty(in: url, from: key, to: newKey)
            }
            // 型が決めてあれば、新しい名前にも同じ型を付ける（ほかのノートが古い名前を使っているかもしれないので、古い方は残す）
            if let types = vault.propertyTypes, let type = types.recorded[key], types.recorded[newKey] == nil {
                types.set(type, for: newKey)
            }
            vault.saveNow()
        }
        editor.onToggleFavorite = { [weak vault] in
            if let url = vault?.activeTab.url { vault?.toggleBookmark(url) }
        }
        editor.tabBar.onSelect = { [weak vault] index in vault?.selectTab(at: index) }
        editor.tabBar.onClose = { [weak vault, weak window] index in
            guard let vault else { return }
            // 分離したウィンドウは、最後のタブを閉じたらウィンドウごと閉じる
            if !isMain, vault.tabs.count == 1 { window?.performClose(nil) } else { vault.closeTab(at: index) }
        }
        editor.tabBar.onMove = { [weak vault] source, destination in vault?.moveTab(from: source, to: destination) }
        editor.tabBar.onDetach = { [unowned self, weak vault, weak editor] index, point in
            guard let vault, let editor else { return }
            detachTab(at: index, of: vault, size: editor.view.frame.size, to: point)
        }
        editor.tabBar.onDragUpdate = { [unowned self, weak editor] point in
            for area in editorAreas { area.tabBar.dropIndex = nil }
            if let editor, let (target, insertion) = tabDestination(at: point, excluding: editor) {
                target.tabBar.dropIndex = insertion
            }
        }
        editor.tabBar.onDragEnd = { [unowned self] in
            for area in editorAreas { area.tabBar.dropIndex = nil }
        }
        editor.tabBar.onDrop = { [unowned self, weak vault, weak editor] index, point in
            guard let vault, let editor, let (target, insertion) = tabDestination(at: point, excluding: editor),
                  let destination = vaultForEditor(target), vault.tabs.indices.contains(index) else { return false }
            let wasLastTab = vault.tabs.count == 1
            let tab = vault.tabs[index]
            let controller = editor.takeContent(for: tab.id)
            if let controller { target.adoptContent(controller, for: tab.id) }
            guard vault.transferTab(at: index, to: destination, at: insertion, preservingContent: controller != nil) else { return false }
            target.view.window?.makeKeyAndOrderFront(nil)
            if wasLastTab, let detached = detachedWindows.first(where: { $0.vault === vault }) {
                detached.window.close()
            }
            return true
        }
        editor.tabBar.onNewTab = { [weak vault] in vault?.newTab() }
        editor.tabBar.onBack = { [weak vault] in vault?.goBack() }
        editor.tabBar.onForward = { [weak vault] in vault?.goForward() }
        vault.viewState = { [weak editor] tab in editor?.viewState(of: tab) }
        vault.onLoad = { [weak editor] tab, document in editor?.show(document, in: tab) }
        vault.isComposing = { [weak editor] tab in editor?.isComposing(in: tab) == true }
        vault.resolveSaveConflict = { url in
            let alert = NSAlert()
            alert.messageText = "ファイルが外部で変更されています"
            alert.informativeText = "「\(url.lastPathComponent)」には Awai の未保存の編集もあります。残す内容を選んでください。"
            alert.addButton(withTitle: "外部の変更を読み込む")
            alert.addButton(withTitle: "Awai の内容で上書き")
            return alert.runModal() == .alertSecondButtonReturn
        }
        vault.onExternalChange = { [unowned self, weak vault, weak editor] in
            guard let vault, let editor else { return }
            editor.notesDidChange()
            updateNoteHeader(of: editor, vault: vault)
        }
        vault.onRequestFocus = { [weak window] in window?.makeKeyAndOrderFront(nil) }
        vault.onTabsChange = { [unowned self, weak vault, weak editor, weak window] in
            guard let vault, let editor, let window else { return }
            editor.update(tabs: vault.tabs, activeIndex: vault.activeIndex,
                          canGoBack: vault.canGoBack, canGoForward: vault.canGoForward)
            let url = vault.activeTab.url
            if isMain {
                sidebar.select(url)
                sidebar.calendarView.selectedDate = url.flatMap { vault.dailyNotes?.date(of: $0) }
            }
            window.title = url?.deletingPathExtension().lastPathComponent ?? "Awai"
            window.subtitle = vault.root?.lastPathComponent ?? ""
            updateNoteHeader(of: editor, vault: vault)
        }
    }

    private func updateNoteHeader(of editor: EditorAreaViewController, vault: Vault) {
        editor.setFavorite(vault.activeTab.url.map { vault.isBookmarked($0) })
        // `.base` の表は左上にビューの切り替えがあるので、パスはノートのときだけ出す
        let url = vault.activeTab.url.flatMap { $0.pathExtension.lowercased() == "base" ? nil : $0 }
        editor.setNotePath(url.flatMap { vault.relativePath(of: $0) })
    }

    // MARK: - 分離したウィンドウ

    private func vaultForEditor(_ area: EditorAreaViewController) -> Vault? {
        area === editor ? vault : detachedWindows.first { $0.editor === area }?.vault
    }

    /// 手前のウィンドウだけを対象にし、本文へのドロップをタブの移動として扱わない。
    private func tabDestination(at point: NSPoint, excluding source: EditorAreaViewController) -> (EditorAreaViewController, Int)? {
        guard let top = NSApp.orderedWindows.first(where: {
            $0.isVisible && !$0.isMiniaturized && !$0.ignoresMouseEvents && $0.frame.contains(point)
        }), let target = editorAreas.first(where: { $0 !== source && $0.view.window === top }),
           let insertion = target.tabBar.insertionIndex(at: point) else { return nil }
        return (target, insertion)
    }

    /// タブをウィンドウの外で離したら、そのタブを新しいウィンドウに移す。ウィンドウはタブがマウスの下に来る位置に置く
    private func detachTab(at index: Int, of source: Vault, size: NSSize, to point: NSPoint) {
        guard source.tabs.count > 1, source.tabs.indices.contains(index),
              let sourceEditor = editorAreas.first(where: { vaultForEditor($0) === source }) else { return }
        let controller = sourceEditor.takeContent(for: source.tabs[index].id)
        guard let (tab, viewState) = source.detachTab(at: index) else { return }
        let size = NSSize(width: max(size.width, 480), height: max(size.height, 320))
        let frame = NSRect(x: point.x - 160, y: point.y + TabBarView.height / 2 - size.height, width: size.width, height: size.height)
        let vault = Vault(sharingFolderWith: source, tab: tab, viewState: viewState, preservingContent: controller != nil)
        let detached = DetachedWindow(vault: vault, frame: frame)
        let editor = detached.editor
        connect(editor, to: vault, in: detached.window)
        if let controller { editor.adoptContent(controller, for: tab.id) }
        vault.onTreeChange = { [weak editor] in editor?.notesDidChange() }
        vault.onBookmarksChange = { [unowned self, weak vault, weak editor] in
            if let vault, let editor { updateNoteHeader(of: editor, vault: vault) }
        }
        vault.onFolderClose = { [weak detached] in detached?.window.close() }
        detached.onClose = { [unowned self] closed in detachedWindows.removeAll { $0 === closed } }
        detachedWindows.append(detached)
        vault.reloadTabs()
        detached.window.makeKeyAndOrderFront(nil)
        keepTrafficLightsPlaced(in: detached.window)
    }

    /// メインウィンドウを閉じたら、分離したウィンドウもすべて閉じる（サイドバーのないウィンドウだけを残さない）
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        for detached in detachedWindows { detached.window.close() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if vault.root == nil { vault.restoreLastRoot() }
        window.makeKeyAndOrderFront(nil)
        keepTrafficLightsPlaced(in: window)
        // マウスの戻る・進むボタン。押したウィンドウのタブを動かす
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [unowned self] event in
            let button = event.buttonNumber
            guard button == 3 || button == 4 else { return event }
            MainActor.assumeIsolated {
                let vault = detachedWindows.first { $0.window === event.window }?.vault ?? vault
                button == 3 ? vault.goBack() : vault.goForward()
            }
            return nil
        }
        // Obsidian などで変えたノート・プロパティ型・ブックマークを反映する。ふだんはフォルダの監視で反映するので、その取りこぼしの保険
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

    /// `open -a Awai ノート.md` や Finder からファイルを渡されたとき
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
    private func keepTrafficLightsPlaced(in window: NSWindow) {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(trafficLightFrameDidChange(_:)), name: NSView.frameDidChangeNotification, object: button
            )
        }
        (window as? AwaiWindow)?.onLayout = { [weak self, weak window] in
            guard let self, let window else { return }
            self.placeTrafficLights(in: window)
        }
        placeTrafficLights(in: window)
    }

    /// 配置中の通知からはフレームを変更できないため、ウィンドウの配置完了時に戻す。
    @objc private func trafficLightFrameDidChange(_ notification: Notification) {
        guard let window = (notification.object as? NSView)?.window else { return }
        guard (window as? AwaiWindow)?.isPlacingTrafficLights != true else { return }
        window.contentView?.needsLayout = true
    }

    /// フルスクリーンではメニューバーと一緒に出るので動かさない
    private func placeTrafficLights(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        var changed = false
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            if placeTrafficLight(button, at: index) { changed = true }
        }
        guard changed else { return }
        // サイドバーを閉じているとき（分離したウィンドウは常に）、タブは緑のボタンの右から並ぶので描き直す
        let editor = detachedWindows.first { $0.window === window }?.editor ?? editor
        editor.tabBar.needsDisplay = true
    }

    @discardableResult
    private func placeTrafficLight(_ button: NSButton, at index: Int) -> Bool {
        guard let superview = button.superview else { return false }
        let top = TrafficLights.centerY - button.frame.height / 2
        let origin = NSPoint(
            x: TrafficLights.leading + CGFloat(index) * TrafficLights.spacing,
            y: superview.isFlipped ? top : superview.bounds.height - top - button.frame.height
        )
        // 自分の変更でも通知が届くので、位置が合っていれば何もしない。
        guard button.frame.origin != origin else { return false }
        button.setFrameOrigin(origin)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        vault.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// `[[ノート名]]` は vault のノートを開き、`[表示名](URL)` は既定のブラウザなど URL に対応するアプリで開く。
    /// スキームのない URL は、開いているノートからの相対パスのノートとして扱う
    private func openLink(_ target: LinkTarget, newTab: Bool, in vault: Vault) {
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

    /// Awai で開けないファイル（画像や PDF など）は Obsidian で開く。Obsidian がなければ既定のアプリに任せる
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
        let vault = activeVault
        guard let url = vault.activeTab.url else { return }
        vault.toggleBookmark(url)
    }

    @objc func goBack(_ sender: Any?) { activeVault.goBack() }
    @objc func goForward(_ sender: Any?) { activeVault.goForward() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let vault = activeVault
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
    /// 検索欄はメインウィンドウのサイドバーにあるので、分離したウィンドウからはメインウィンドウを前に出す
    @objc func showFileSearch(_ sender: Any?) {
        if activeDetached != nil { window.makeKeyAndOrderFront(nil) }
        sidebar.focusSearch()
    }
    /// 保存待ちの本文はウィンドウをまたいで持つので、どのウィンドウからでもまとめて書く
    @objc func save(_ sender: Any?) { vault.saveNow() }
    @objc func newTab(_ sender: Any?) { activeVault.newTab() }
    /// 何も開いていないタブが1つだけなら、ウィンドウを閉じる。分離したウィンドウは最後のタブを閉じたら閉じる
    @objc func closeTab(_ sender: Any?) {
        if let detached = activeDetached {
            let vault = detached.vault
            if vault.tabs.count == 1 { detached.window.performClose(sender) } else { vault.closeTab(at: vault.activeIndex) }
        } else if vault.tabs.count == 1, vault.activeTab.url == nil {
            window.performClose(sender)
        } else {
            vault.closeTab(at: vault.activeIndex)
        }
    }
    @objc func selectNextTab(_ sender: Any?) {
        let vault = activeVault
        vault.selectTab(at: (vault.activeIndex + 1) % vault.tabs.count)
    }
    @objc func selectPreviousTab(_ sender: Any?) {
        let vault = activeVault
        vault.selectTab(at: (vault.activeIndex + vault.tabs.count - 1) % vault.tabs.count)
    }
    /// ⌘1〜⌘8 はその番号のタブ、⌘9 は右端のタブ
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let vault = activeVault
        vault.selectTab(at: sender.tag == 9 ? vault.tabs.count - 1 : sender.tag - 1)
    }
    @objc func openTodayNote(_ sender: Any?) {
        activeVault.openDailyNote(for: Date())
        sidebar.calendarView.show(month: Date())
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Awai を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Awai")

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
    /// サイドバー上端のボタン（ファイル・お気に入り）の左端と、1つの幅
    static let sidebarButtonsLeading: CGFloat = trailing + 15
    static let sidebarButtonWidth: CGFloat = 26
    /// サイドバーの開閉ボタンの幅と、サイドバーの右端からの余白。閉じたときはタブバーの左端（信号機ボタンの右）に同じ幅で出す
    static let sidebarToggleWidth: CGFloat = sidebarButtonWidth
    static let sidebarToggleTrailing: CGFloat = 8
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

// エディタやサイドバーは作るときに設定を読むので、AppDelegate より先に引き継ぐ
AppDefaults.migrateFromMa()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
