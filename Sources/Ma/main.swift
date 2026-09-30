import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let vault = Vault()
    private let sidebar = SidebarViewController()
    private let editor = EditorAreaViewController()
    private var window: NSWindow!

    /// ファイルを渡されて起動したときは didFinishLaunching より先に open が呼ばれるので、画面はここで作る
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
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
        window.center()
        window.setFrameAutosaveName("main")
        window.title = "Ma"
        window.titlebarSeparatorStyle = .none
        // タイトルバーの帯と文字は出さず、信号機ボタンだけ本文の上に重ねる（タイトルは Mission Control やウィンドウメニューで使われる）
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        sidebar.onSelect = { [vault] url, newTab in vault.open(url, newTab: newTab) }
        editor.onChange = { [vault] url, text in vault.textDidChange(text, url: url) }
        editor.tabBar.onSelect = { [vault] index in vault.selectTab(at: index) }
        editor.tabBar.onClose = { [vault] index in vault.closeTab(at: index) }
        editor.tabBar.onMove = { [vault] source, destination in vault.moveTab(from: source, to: destination) }
        editor.tabBar.onNewTab = { [vault] in vault.newTab() }
        vault.onTreeChange = { [unowned self] in
            sidebar.reload(vault.tree)
            sidebar.select(vault.activeTab.url)
        }
        sidebar.calendarView.onSelectDate = { [vault] date in vault.openDailyNote(for: date) }
        vault.onNotesChange = { [unowned self] in
            let calendar = sidebar.calendarView
            calendar.firstWeekday = vault.dailyNotes?.settings.firstWeekday ?? Calendar.current.firstWeekday
            calendar.hasNote = vault.dailyNotes.map { notes in { notes.exists(for: $0) } }
        }
        vault.onLoad = { [unowned self] tab, document in editor.show(document, in: tab) }
        vault.onTabsChange = { [unowned self] in
            editor.update(tabs: vault.tabs, activeIndex: vault.activeIndex)
            let url = vault.activeTab.url
            sidebar.select(url)
            sidebar.calendarView.selectedDate = url.flatMap { vault.dailyNotes?.date(of: $0) }
            window.title = url?.deletingPathExtension().lastPathComponent ?? "Ma"
            window.subtitle = vault.root?.lastPathComponent ?? ""
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if vault.root == nil { vault.restoreLastRoot() }
        window.makeKeyAndOrderFront(nil)

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

    func applicationWillTerminate(_ notification: Notification) {
        vault.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openFolder(_ sender: Any?) { vault.chooseFolder() }
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
        file.addItem(withTitle: "保存", action: #selector(save(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "今日のデイリーノート", action: #selector(openTodayNote(_:)), keyEquivalent: "d")
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
        let find = edit.addItem(withTitle: "検索…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        main.addItem(submenu: edit, title: "編集")

        let view = NSMenu(title: "表示")
        view.addItem(withTitle: "ソース表示", action: #selector(EditorAreaViewController.toggleSourceMode(_:)), keyEquivalent: "e")
        let toggle = view.addItem(withTitle: "サイドバーを切り替え", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.command, .control]
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
