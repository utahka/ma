import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let vault = Vault()
    private let sidebar = SidebarViewController()
    private let editor = EditorViewController()
    private var window: NSWindow!

    /// ファイルを渡されて起動したときは didFinishLaunching より先に open が呼ばれるので、画面はここで作る
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: editor))

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

        sidebar.onSelect = { [vault] url in vault.open(url) }
        editor.onChange = { [vault] text in vault.textDidChange(text) }
        vault.onTreeChange = { [unowned self] in sidebar.reload(vault.tree) }
        sidebar.calendarView.onSelectDate = { [vault] date in vault.openDailyNote(for: date) }
        vault.onNotesChange = { [unowned self] in
            let calendar = sidebar.calendarView
            calendar.firstWeekday = vault.dailyNotes?.settings.firstWeekday ?? Calendar.current.firstWeekday
            calendar.hasNote = vault.dailyNotes.map { notes in { notes.exists(for: $0) } }
        }
        vault.onDocumentChange = { [unowned self] in
            editor.show(vault.document)
            sidebar.calendarView.selectedDate = vault.document.flatMap { vault.dailyNotes?.date(of: $0.url) }
            window.title = vault.document?.url.deletingPathExtension().lastPathComponent ?? "Ma"
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
            vault.open(url)
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
        file.addItem(withTitle: "フォルダを開く…", action: #selector(openFolder(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "保存", action: #selector(save(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "今日のデイリーノート", action: #selector(openTodayNote(_:)), keyEquivalent: "d")
        file.addItem(.separator())
        file.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        view.addItem(withTitle: "ソース表示", action: #selector(EditorViewController.toggleSourceMode(_:)), keyEquivalent: "e")
        let toggle = view.addItem(withTitle: "サイドバーを切り替え", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu: view, title: "表示")

        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
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
