import AppKit

final class FileNode {
    let url: URL
    let isDirectory: Bool
    let children: [FileNode]

    init(url: URL, isDirectory: Bool, children: [FileNode] = []) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
    }

    var name: String {
        isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}

/// アプリの設定の保存先。動作確認では環境変数 MA_DEFAULTS_SUITE で別の保存先を指定し、
/// ふだん使っている設定（最後に開いた vault など）を書き換えないようにする
enum AppDefaults {
    nonisolated(unsafe) static let shared: UserDefaults =
        ProcessInfo.processInfo.environment["MA_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
}

/// エディタに渡す開いているノート
struct OpenDocument {
    let url: URL
    let text: String
    /// 戻る・進むで開いたときに復元する表示位置
    var viewState: NoteViewState? = nil
    /// 開いているノートを外部の変更で読み直したとき。エディタは違う部分だけを差し替え、表示位置とフォーカスを動かさない
    /// （サイドバーの検索欄などで入力中のことがある）
    var isReload = false
}

/// ノートのカーソルとスクロールの位置
struct NoteViewState {
    var selection: NSRange
    /// 画面の上端にある文字の位置
    var topCharacter: Int
}

/// 戻る・進むの行き先
struct HistoryEntry {
    let url: URL
    var viewState: NoteViewState?
}

/// タブ。`url` が nil のときは何も開いていない新しいタブ
struct Tab: Identifiable {
    let id = UUID()
    var url: URL?
    /// タブの中でノートを切り替えた履歴。新しいものが末尾
    var back: [HistoryEntry] = []
    var forward: [HistoryEntry] = []

    var title: String { url?.deletingPathExtension().lastPathComponent ?? "新しいタブ" }
}

/// ウィンドウをまたいで共有する vault の状態（フォルダ・ファイル一覧・お気に入り・保存待ちの本文）。
/// タブと履歴はウィンドウごとの `Vault` が持つ
@MainActor
private final class VaultFolder {
    var root: URL?
    var tree: [FileNode] = []
    var dailyNotes: DailyNotes?
    var propertyTypes: PropertyTypes?
    var bookmarks: [Bookmark] = []
    var bookmarksData: Data?
    var bookmarksLoaded = false
    var pendingTexts: [URL: String] = [:]
    var diskTexts: [URL: String] = [:]
    var saveTask: Task<Void, Never>?
    var baseCache: [String: (modified: Date, base: BaseFile?)] = [:]
    /// vault のファイルの変更を見張る。外部で変わったノートやファイル一覧をすぐに反映する
    var watcher: FolderWatcher?
    /// 変換中のノートがあって読み直しを見送ったとき、あとで読み直す
    var retryTask: Task<Void, Never>?

    private struct WeakVault { weak var vault: Vault? }
    private var members: [WeakVault] = []
    /// このフォルダを開いているウィンドウのタブ。先頭がメインウィンドウ
    var vaults: [Vault] { members.compactMap(\.vault) }

    func add(_ vault: Vault) { members.append(WeakVault(vault: vault)) }
    func remove(_ vault: Vault) { members.removeAll { $0.vault == nil || $0.vault === vault } }
}

/// 開いているフォルダ（vault）と、1つのウィンドウのタブで開いているノートの読み書きを受け持つ。
/// 分離したウィンドウは `init(sharingFolderWith:tab:viewState:)` で作り、フォルダの状態と保存はメインウィンドウと共有する
@MainActor
final class Vault {
    private let folder: VaultFolder
    private(set) var root: URL? { get { folder.root } set { folder.root = newValue } }
    private(set) var tree: [FileNode] { get { folder.tree } set { folder.tree = newValue } }
    private(set) var dailyNotes: DailyNotes? { get { folder.dailyNotes } set { folder.dailyNotes = newValue } }
    private(set) var propertyTypes: PropertyTypes? { get { folder.propertyTypes } set { folder.propertyTypes = newValue } }
    /// 同じファイルを2つのタブで開くことはない（開こうとしたらそのタブに切り替える）。ほかのウィンドウのタブとも重ねない
    private(set) var tabs = [Tab()]
    private(set) var activeIndex = 0
    var activeTab: Tab { tabs[activeIndex] }
    private(set) var bookmarks: [Bookmark] { get { folder.bookmarks } set { folder.bookmarks = newValue } }

    var onTreeChange: (() -> Void)?
    /// タブの並び・選択中のタブ・タブで開いているファイルが変わったとき
    var onTabsChange: (() -> Void)?
    /// タブにノートを読み込んだとき（nil は空のタブ）
    var onLoad: ((Tab.ID, OpenDocument?) -> Void)?
    /// vault を開いたときとデイリーノートを作ったとき（カレンダーの点を打ち直す）
    var onNotesChange: (() -> Void)?
    var onBookmarksChange: (() -> Void)?
    /// タブで開いているノートの今の表示位置。別のノートに切り替える前に履歴へ残す
    var viewState: ((Tab.ID) -> NoteViewState?)?
    /// 外部変更と未保存の編集がぶつかったときに、自分の編集で上書きするなら true
    var resolveSaveConflict: ((URL) -> Bool)?
    /// タブで日本語の変換中（未確定の文字がある）なら true。変換中は外部の変更で読み直さない
    var isComposing: ((Tab.ID) -> Bool)?
    /// ノートやプロパティ型が外部で変わったとき
    var onExternalChange: (() -> Void)?
    /// ほかのウィンドウで開いているノートを開こうとして、このウィンドウのタブに切り替えたとき（ウィンドウを前面に出す）
    var onRequestFocus: (() -> Void)?
    /// メインウィンドウで別の vault を開いたとき。分離したウィンドウを閉じる
    var onFolderClose: (() -> Void)?

    private var pendingTexts: [URL: String] { get { folder.pendingTexts } set { folder.pendingTexts = newValue } }
    /// 最後に読み込み、または保存したディスク上の本文。外部変更との競合判定に使う
    private var diskTexts: [URL: String] { get { folder.diskTexts } set { folder.diskTexts = newValue } }
    private var saveTask: Task<Void, Never>? { get { folder.saveTask } set { folder.saveTask = newValue } }
    /// 中身を読み込み済みのタブ。復元したタブは選ばれたときに読む
    private var loadedTabs: Set<Tab.ID> = []
    /// 戻る・進むで開いたタブの、読み込んだときに復元する表示位置
    private var restoringViewStates: [Tab.ID: NoteViewState] = [:]
    /// 次回の起動で開く vault のときだけ、開いているタブも記録する
    private var remembersTabs = false
    /// 最後に読んだ bookmarks.json の中身（nil はファイルがない）。変わっていなければ読み直さない
    private var bookmarksData: Data? { get { folder.bookmarksData } set { folder.bookmarksData = newValue } }
    private var bookmarksLoaded: Bool { get { folder.bookmarksLoaded } set { folder.bookmarksLoaded = newValue } }

    private static let lastRootKey = "lastRoot"
    private static let tabsKey = "openTabs"
    private static let activeTabKey = "activeTab"

    /// メインウィンドウ用
    init() {
        folder = VaultFolder()
        folder.add(self)
    }

    /// 分離したウィンドウ用。フォルダ・ファイル一覧・お気に入り・保存待ちの本文は `other` と共有し、タブだけを別に持つ。
    /// 開いているタブは記録しない（起動時に戻すのはメインウィンドウのタブだけ）。コールバックを設定してから `reloadTabs()` で読み込む
    init(sharingFolderWith other: Vault, tab: Tab, viewState: NoteViewState?, preservingContent: Bool = false) {
        folder = other.folder
        tabs = [tab]
        if preservingContent { loadedTabs.insert(tab.id) }
        if let viewState { restoringViewStates[tab.id] = viewState }
        folder.add(self)
    }

    /// 分離したウィンドウを閉じるとき。保存待ちの編集を書き、フォルダの共有から外れる
    func leaveFolder() {
        saveNow()
        folder.remove(self)
    }

    /// 同じフォルダを開いているすべてのウィンドウに知らせる
    private func broadcast(_ callback: KeyPath<Vault, (() -> Void)?>) {
        for vault in folder.vaults { vault[keyPath: callback]?() }
    }

    func restoreLastRoot() {
        guard let path = AppDefaults.shared.string(forKey: Self.lastRootKey),
              FileManager.default.fileExists(atPath: path)
        else { return }
        // setRoot がタブの記録を空のタブで上書きするので、先に読んでおく
        let paths = AppDefaults.shared.stringArray(forKey: Self.tabsKey) ?? []
        let active = AppDefaults.shared.integer(forKey: Self.activeTabKey)
        setRoot(URL(fileURLWithPath: path, isDirectory: true))
        let restored = paths
            .filter { $0.hasPrefix(path + "/") && FileManager.default.fileExists(atPath: $0) }
            .map { Tab(url: URL(fileURLWithPath: $0)) }
        guard !restored.isEmpty else { return }
        tabs = restored
        activeIndex = min(max(active, 0), restored.count - 1)
        tabsDidChange()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "開く"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setRoot(url)
    }

    /// `remember` が false のときは、次回の起動で開く vault として記録しない（vault の外のファイルを開いたときなど）
    func setRoot(_ url: URL, remember: Bool = true) {
        // 分離したウィンドウは前の vault のノートを開いているので閉じる（閉じるときに保存する）
        for vault in folder.vaults where vault !== self { vault.onFolderClose?() }
        saveNow()
        root = url
        tree = []
        dailyNotes = DailyNotes(root: url)
        propertyTypes = PropertyTypes(root: url)
        remembersTabs = remember
        tabs = [Tab()]
        activeIndex = 0
        loadedTabs = []
        diskTexts = [:]
        pendingTexts = [:]
        bookmarks = []
        bookmarksLoaded = false
        folder.watcher?.stop()
        folder.watcher = FolderWatcher(root: url) { [weak folder] change in
            // 分離したウィンドウが閉じても残るよう、メインウィンドウの Vault に任せる
            folder?.vaults.first?.applyFileChanges(change)
        }
        if folder.watcher == nil { NSLog("フォルダの監視を始められない: \(url.path)") }
        broadcast(\.onTreeChange)
        tabsDidChange()
        broadcast(\.onNotesChange)
        if remember { AppDefaults.shared.set(url.path, forKey: Self.lastRootKey) }
        rescan()
        reloadBookmarks()
    }

    /// Obsidian で変えたブックマークも拾えるよう、vault を開いたときとアプリが前面に来たときに読み直す
    func reloadBookmarks() {
        guard let root, let (document, data) = Bookmarks.readDocument(root: root) else { return }
        guard !bookmarksLoaded || data != bookmarksData else { return }
        bookmarksLoaded = true
        bookmarksData = data
        bookmarks = Bookmarks.parse(document["items"] as? [Any] ?? [], root: root)
        broadcast(\.onBookmarksChange)
    }

    func isBookmarked(_ url: URL) -> Bool {
        guard let path = relativePath(of: url) else { return false }
        func contains(_ bookmarks: [Bookmark]) -> Bool {
            bookmarks.contains { bookmark in
                if case .group(let children) = bookmark.kind { return contains(children) }
                return bookmark.path.map { Bookmarks.samePath($0, path) } == true
            }
        }
        return contains(bookmarks)
    }

    /// ノートかフォルダをブックマークに加える。すでにあれば（グループの中も含めて）外す
    func toggleBookmark(_ url: URL) {
        guard let path = relativePath(of: url) else { return }
        updateBookmarks { items in
            if Bookmarks.contains(path: path, in: items) { return Bookmarks.removing(path: path, from: items) }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let item: [String: Any] = [
                "type": isDirectory ? "folder" : "file",
                "ctime": Int64(Date().timeIntervalSince1970 * 1000),
                "path": path,
            ]
            return items + [item]
        }
    }

    /// Obsidian の設定（`.obsidian/app.json`）を読む。なければ空
    private var obsidianAppSettings: [String: Any] {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent(".obsidian/app.json")) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// 削除の前に確かめるかどうか。Obsidian の「ファイルの削除を確認する」（`promptDelete`、既定はオン）に合わせる
    var promptsDelete: Bool { obsidianAppSettings["promptDelete"] as? Bool ?? true }

    /// ノートかフォルダを削除し、その中を開いているタブを閉じる。消し方は Obsidian の `trashOption` に合わせ、
    /// 既定（`system`）はシステムのゴミ箱、`local` は vault の `.trash`、`none` は完全に消す
    func deleteItem(_ url: URL) throws {
        guard let root, relativePath(of: url) != nil else { return }
        // 保存待ちの本文が消したあとに書き戻されないよう、先に書いておく
        saveNow()
        switch obsidianAppSettings["trashOption"] as? String {
        case "local":
            let trash = root.appendingPathComponent(".trash", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            var destination = trash.appendingPathComponent(url.lastPathComponent)
            var number = 1
            while FileManager.default.fileExists(atPath: destination.path) {
                number += 1
                let name = url.deletingPathExtension().lastPathComponent + " \(number)"
                destination = trash.appendingPathComponent(url.pathExtension.isEmpty ? name : name + "." + url.pathExtension)
            }
            try FileManager.default.moveItem(at: url, to: destination)
        case "none":
            try FileManager.default.removeItem(at: url)
        default:
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        for vault in folder.vaults { vault.closeTabs(inside: url) }
        rescan()
    }

    /// 消したノート（フォルダならその中のノート）を開いているタブを、保存せずに閉じる
    private func closeTabs(inside url: URL) {
        let removed = { (tab: Tab) in tab.url.map { $0.path == url.path || $0.path.hasPrefix(url.path + "/") } == true }
        guard tabs.contains(where: removed) else { return }
        let active = activeTab.id
        let activeRemoved = removed(activeTab)
        for tab in tabs where removed(tab) { loadedTabs.remove(tab.id) }
        let before = tabs.firstIndex { $0.id == active } ?? 0
        tabs.removeAll(where: removed)
        if tabs.isEmpty { tabs = [Tab()] }
        activeIndex = activeRemoved ? min(before, tabs.count - 1) : tabs.firstIndex { $0.id == active } ?? 0
        tabsDidChange()
    }

    /// 表示中のブックマークを外す。表示した後にファイルが変わっていたら位置がずれるので、読み直すだけにする
    func removeBookmark(at indexPath: [Int]) {
        updateBookmarks(requiresUnchanged: true) { Bookmarks.removing(at: indexPath, from: $0) }
    }

    private func updateBookmarks(requiresUnchanged: Bool = false, _ change: ([Any]) -> [Any]) {
        guard let root else { return }
        guard case (var document, let data)? = Bookmarks.readDocument(root: root) else {
            NSLog("ブックマークを読めないので変更しない: \(Bookmarks.fileURL(root: root).path)")
            return
        }
        guard !requiresUnchanged || data == bookmarksData else {
            reloadBookmarks()
            return
        }
        document["items"] = change(document["items"] as? [Any] ?? [])
        do {
            try Bookmarks.write(document, root: root)
        } catch {
            NSLog("ブックマークの保存に失敗: \(error)")
        }
        reloadBookmarks()
    }

    /// vault からの相対パス。Obsidian に合わせて合成形（NFC）にする
    func relativePath(of url: URL) -> String? {
        guard let root, url.path.hasPrefix(root.path + "/") else { return nil }
        return String(url.path.dropFirst(root.path.count + 1)).precomposedStringWithCanonicalMapping
    }

    private func rescan() {
        guard let url = root else { return }
        Task {
            let scanned = await Task.detached { Self.scan(url) }.value
            guard root == url else { return }
            tree = scanned
            broadcast(\.onTreeChange)
        }
    }

    /// その日のデイリーノートを開く。なければテンプレートから作る
    func openDailyNote(for date: Date) {
        guard let dailyNotes else { return }
        let url = dailyNotes.url(for: date)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try dailyNotes.initialText(for: date).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("デイリーノートの作成に失敗: \(url.path): \(error)")
                return
            }
            rescan()
            broadcast(\.onNotesChange)
        }
        open(url)
    }

    /// ノートを開く。すでに開いているタブがあればそこへ切り替える（URL は濁点の合成・分解の違いで一致しないことがあるので、パスの文字列で比べる）。
    /// `newTab` のときは選択中のタブの右に新しいタブを開く（選択中のタブが空ならそこで開く）
    func open(_ url: URL, newTab: Bool = false) {
        if let index = tabs.firstIndex(where: { $0.url?.path == url.path }) {
            selectTab(at: index)
            return
        }
        if let (other, index) = otherWindowTab(showing: url) {
            other.selectTab(at: index)
            other.onRequestFocus?()
            return
        }
        saveNow()
        if newTab, activeTab.url != nil {
            activeIndex += 1
            tabs.insert(Tab(url: url), at: activeIndex)
        } else {
            if let current = activeTab.url {
                tabs[activeIndex].back.append(HistoryEntry(url: current, viewState: viewState?(activeTab.id)))
                tabs[activeIndex].forward = []
            }
            tabs[activeIndex].url = url
            loadedTabs.remove(activeTab.id)
        }
        tabsDidChange()
    }

    var canGoBack: Bool { activeTab.back.contains(where: canNavigate) }
    var canGoForward: Bool { activeTab.forward.contains(where: canNavigate) }

    func goBack() { navigate(forward: false) }
    func goForward() { navigate(forward: true) }

    /// 消えたファイルと、ほかのタブ（ほかのウィンドウも含む）で開いているファイル（同じファイルは2つのタブで開かない）は飛ばす
    private func canNavigate(to entry: HistoryEntry) -> Bool {
        FileManager.default.fileExists(atPath: entry.url.path)
            && !tabs.contains { $0.id != activeTab.id && $0.url?.path == entry.url.path }
            && otherWindowTab(showing: entry.url) == nil
    }

    /// ほかのウィンドウでそのファイルを開いているタブ
    private func otherWindowTab(showing url: URL) -> (Vault, Int)? {
        for vault in folder.vaults where vault !== self {
            if let index = vault.tabs.firstIndex(where: { $0.url?.path == url.path }) { return (vault, index) }
        }
        return nil
    }

    private func navigate(forward: Bool) {
        var tab = activeTab
        guard let current = tab.url else { return }
        var entry: HistoryEntry?
        while entry == nil, let candidate = forward ? tab.forward.popLast() : tab.back.popLast() {
            if canNavigate(to: candidate) { entry = candidate }
        }
        guard let entry else { return }
        saveNow()
        let leaving = HistoryEntry(url: current, viewState: viewState?(tab.id))
        if forward { tab.back.append(leaving) } else { tab.forward.append(leaving) }
        tab.url = entry.url
        tabs[activeIndex] = tab
        loadedTabs.remove(tab.id)
        restoringViewStates[tab.id] = entry.viewState
        tabsDidChange()
    }

    func newTab() {
        activeIndex += 1
        tabs.insert(Tab(), at: activeIndex)
        tabsDidChange()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else { return }
        saveNow()
        activeIndex = index
        tabsDidChange()
        reloadChangedNotes()
    }

    /// 閉じたのが選択中のタブなら右隣（右端なら左隣）を選ぶ。最後の1つを閉じたら空のタブを残す
    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        saveNow()
        loadedTabs.remove(tabs[index].id)
        tabs.remove(at: index)
        if tabs.isEmpty { tabs = [Tab()] }
        if index < activeIndex || activeIndex == tabs.count { activeIndex -= 1 }
        tabsDidChange()
    }

    /// タブを別のウィンドウへ移すために取り外し、表示位置と一緒に返す。タブが1つだけなら取り外さない
    func detachTab(at index: Int) -> (tab: Tab, viewState: NoteViewState?)? {
        guard tabs.count > 1, tabs.indices.contains(index) else { return nil }
        saveNow()
        let tab = tabs[index]
        let state = viewState?(tab.id)
        loadedTabs.remove(tab.id)
        tabs.remove(at: index)
        if index < activeIndex || activeIndex == tabs.count { activeIndex -= 1 }
        tabsDidChange()
        return (tab, state)
    }

    /// 同じフォルダの別ウィンドウへタブと履歴を移す。最後のタブには空のタブを残す。
    func transferTab(at index: Int, to destination: Vault, at insertion: Int, preservingContent: Bool) -> Bool {
        guard destination !== self, destination.folder === folder, tabs.indices.contains(index),
              insertion >= 0, insertion <= destination.tabs.count else { return false }
        saveNow()
        let tab = tabs[index]
        let state = viewState?(tab.id)
        loadedTabs.remove(tab.id)
        restoringViewStates[tab.id] = nil
        tabs.remove(at: index)
        if tabs.isEmpty { tabs = [Tab()] }
        if index < activeIndex || activeIndex == tabs.count { activeIndex -= 1 }
        destination.tabs.insert(tab, at: insertion)
        destination.activeIndex = insertion
        if preservingContent { destination.loadedTabs.insert(tab.id) }
        else if let state { destination.restoringViewStates[tab.id] = state }
        tabsDidChange()
        destination.tabsDidChange()
        return true
    }

    /// 選択中のタブを読み込み、タブの表示を揃え直す（分離したウィンドウを作った直後に使う）
    func reloadTabs() { tabsDidChange() }

    func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), tabs.indices.contains(destination), source != destination else { return }
        let active = activeTab.id
        tabs.insert(tabs.remove(at: source), at: destination)
        activeIndex = tabs.firstIndex { $0.id == active } ?? 0
        tabsDidChange()
    }

    /// 選択中のタブをまだ読み込んでいなければ読み込み、変更を知らせて記録する
    private func tabsDidChange() {
        let tab = activeTab
        if !loadedTabs.contains(tab.id) {
            loadedTabs.insert(tab.id)
            if let url = tab.url {
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    diskTexts[url] = text
                    onLoad?(tab.id, OpenDocument(url: url, text: text, viewState: restoringViewStates.removeValue(forKey: tab.id)))
                } catch {
                    NSLog("読み込みに失敗: \(url.path): \(error)")
                    onLoad?(tab.id, nil)
                }
            } else {
                onLoad?(tab.id, nil)
            }
        }
        onTabsChange?()
        if remembersTabs {
            AppDefaults.shared.set(tabs.compactMap { $0.url?.path }, forKey: Self.tabsKey)
            AppDefaults.shared.set(activeIndex, forKey: Self.activeTabKey)
        }
    }

    /// `[[ノート名]]` のリンク先。Obsidian と同じく、フォルダを含まない名前は vault 全体からファイル名で探し、
    /// 同じ名前が複数あれば開いているノートと同じフォルダ、なければ浅い位置のものを選ぶ。見つからなければ vault の直下に作る
    func noteURL(forLink name: String) -> URL? {
        guard let root, !name.isEmpty else { return nil }
        let file = name.lowercased().hasSuffix(".md") ? name : name + ".md"
        // ファイル名は濁点が分解形（NFD）で返ってくることがあるので、合成形にそろえて比べる
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        let wanted = key(file)
        let candidates = FileNode.notes(in: tree).filter { note in
            let path = key(String(note.path.dropFirst(root.path.count + 1)))
            return path == wanted || path.hasSuffix("/" + wanted)
        }
        let folder = activeTab.url.map { key($0.deletingLastPathComponent().path) }
        if let found = candidates.first(where: { key($0.deletingLastPathComponent().path) == folder })
            ?? candidates.min(by: { $0.pathComponents.count < $1.pathComponents.count }) {
            return found
        }

        // vault の外には作らない
        guard !file.split(separator: "/").contains("..") else { return nil }
        let url = root.appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "".write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("ノートの作成に失敗: \(url.path): \(error)")
                return nil
            }
            rescan()
        }
        return url
    }

    /// 編集のたびに呼ばれる。0.5 秒入力が止まったら保存する
    func textDidChange(_ text: String, url: URL) {
        pendingTexts[url] = text
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        for (url, text) in pendingTexts {
            let current = try? String(contentsOf: url, encoding: .utf8)
            if let known = diskTexts[url], current != known, current != text,
               resolveSaveConflict?(url) != true {
                if let current {
                    diskTexts[url] = current
                    // 保存待ちの本文はウィンドウをまたいで持つので、そのノートを開いているウィンドウで読み直す
                    for vault in folder.vaults {
                        guard let tab = vault.tabs.first(where: { $0.url?.path == url.path }) else { continue }
                        vault.onLoad?(tab.id, OpenDocument(url: url, text: current, viewState: vault.viewState?(tab.id)))
                    }
                }
                continue
            }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                diskTexts[url] = text
            } catch {
                NSLog("保存に失敗: \(url.path): \(error)")
            }
        }
        pendingTexts = [:]
    }

    /// アプリが前面に戻ったとき、外部で変わったノート・プロパティ型・ファイル一覧・お気に入りを読み直す。
    /// ふだんは `FolderWatcher` で反映するので、監視を始められなかったときや通知を取りこぼしたときの保険
    func refreshExternalChanges() {
        reloadChangedNotes()
        rescan()
        reloadBookmarks()
    }

    /// 開いているノート（すべてのウィンドウ）とプロパティ型のうち、外部で変わったものを読み直す。
    /// タブの切り替えのたびに呼ぶので vault 全体は走査しない
    private func reloadChangedNotes() {
        folder.retryTask?.cancel()
        var changed = propertyTypes?.reload() == true
        var deferred = false
        for vault in folder.vaults {
            let result = vault.reloadChangedTabs()
            if result.changed { changed = true }
            if result.deferred { deferred = true }
        }
        if changed { broadcast(\.onExternalChange) }
        if deferred {
            folder.retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.reloadChangedNotes()
            }
        }
    }

    /// このウィンドウのタブで開いているノートのうち、外部で変わったものを読み直す。
    /// 未保存の編集があるノートは読み直さず、保存するときに `resolveSaveConflict` で選んでもらう。
    /// 変換中のノートは見送り、`deferred` を返す
    private func reloadChangedTabs() -> (changed: Bool, deferred: Bool) {
        var changed = false
        var deferred = false
        for tab in tabs where loadedTabs.contains(tab.id) {
            guard let url = tab.url, pendingTexts[url] == nil,
                  let text = try? String(contentsOf: url, encoding: .utf8), text != diskTexts[url]
            else { continue }
            if isComposing?(tab.id) == true {
                deferred = true
                continue
            }
            diskTexts[url] = text
            changed = true
            if tab.id == activeTab.id {
                onLoad?(tab.id, OpenDocument(url: url, text: text, viewState: viewState?(tab.id), isReload: true))
            } else {
                // 選んだときに読み直す。カーソルとスクロールの位置はそのときに戻す
                if let state = viewState?(tab.id) { restoringViewStates[tab.id] = state }
                loadedTabs.remove(tab.id)
            }
        }
        return (changed, deferred)
    }

    /// `FolderWatcher` が知らせた変更を反映する。開いているノートは読み直し（Ma 自身の保存は `diskTexts` と同じなので読み直さない）、
    /// ノートの追加・削除・名前の変更ならファイル一覧を作り直し、`.obsidian` の types.json・bookmarks.json も読み直す
    fileprivate func applyFileChanges(_ change: FolderWatcher.Change) {
        guard let root else { return }
        if change.needsFullScan {
            refreshExternalChanges()
            broadcast(\.onNotesChange)
            return
        }
        // FSEvents はシンボリックリンクを解決したパスで返す
        let prefixes = Set([root.path, root.resolvingSymlinksInPath().path]).map { $0 + "/" }
        func relative(_ path: String) -> String? {
            prefixes.first { path.hasPrefix($0) }.map { String(path.dropFirst($0.count)).precomposedStringWithCanonicalMapping }
        }
        var treePaths: Set<String> = []
        func collect(_ nodes: [FileNode]) {
            for node in nodes {
                if let path = relative(node.url.path) { treePaths.insert(path) }
                collect(node.children)
            }
        }
        collect(tree)
        let openPaths = Set(folder.vaults.flatMap(\.tabs).compactMap { $0.url.flatMap { relative($0.path) } })

        var needsRescan = false
        var otherNoteChanged = false
        var settingsChanged = false
        for path in change.paths {
            guard let name = relative(path) else { continue }
            let components = name.split(separator: "/")
            if components.contains(where: { $0.hasPrefix(".") }) {
                if name == ".obsidian/types.json" || name == ".obsidian/bookmarks.json" { settingsChanged = true }
                continue
            }
            let isNote = ["md", "base"].contains((name as NSString).pathExtension.lowercased())
            if change.movedPaths.contains(path) {
                // 保存でも一時ファイルからの名前の変更が届くので、一覧との食い違いがあるときだけ作り直す
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                if isNote || isDirectory.boolValue || treePaths.contains(name) {
                    if exists != treePaths.contains(name) { needsRescan = true }
                }
            }
            if isNote && !openPaths.contains(name) { otherNoteChanged = true }
        }

        reloadChangedNotes()
        if settingsChanged { reloadBookmarks() }
        if needsRescan {
            rescan()
            broadcast(\.onNotesChange)
        } else if otherNoteChanged {
            // 開いていないノートが変わったら `.base` の表を作り直す
            broadcast(\.onExternalChange)
        }
    }

    /// タブで開いていないノートのプロパティを、ファイルを直接書き換えて設定する
    func setProperty(in url: URL, _ key: String, to value: PropertyValue, type: PropertyType) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let updated = Frontmatter.setting(key, to: value, type: type, in: text)
            if updated != text { try updated.write(to: url, atomically: true, encoding: .utf8) }
        } catch {
            NSLog("プロパティの保存に失敗: \(url.path): \(error)")
        }
    }

    /// ファイルのプロパティ名を変える。キーの行の名前だけを差し替え、値や行の位置は変えない。
    /// 新しい名前のキーがすでにあれば上書きせず false を返す
    @discardableResult
    func renameProperty(in url: URL, from key: String, to newKey: String) -> Bool {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let frontmatter = Frontmatter.parse(text), frontmatter.entry(newKey) == nil,
                  let edit = frontmatter.renaming(key, to: newKey, in: text) else { return false }
            let updated = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("プロパティ名の変更に失敗: \(url.path): \(error)")
            return false
        }
    }

    /// 読み込んだ `.base`。更新日時が変わるまで使い回す
    private var baseCache: [String: (modified: Date, base: BaseFile?)] {
        get { folder.baseCache }
        set { folder.baseCache = newValue }
    }

    /// ノートが対象の `.base` に書かれた `ma:` の型。キーはプロパティ名（`note.` なし）。
    /// 複数の `.base` に当てはまるときは合わせる（同じプロパティは先に見つけた方）
    func propertySchemas(for url: URL, text: String) -> [String: PropertySchema] {
        guard let root else { return [:] }
        let bases = FileNode.files(in: tree).filter { $0.pathExtension.lowercased() == "base" }.compactMap(base(at:))
        guard bases.contains(where: { !$0.schemas.isEmpty }) else { return [:] }
        var properties: [String: PropertyValue] = [:]
        for entry in Frontmatter.parse(text)?.entries ?? [] { properties[entry.key] = entry.value }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let note = NoteRecord(
            url: url, path: String(url.path.dropFirst(root.path.count + 1)), properties: properties,
            created: attributes?[.creationDate] as? Date ?? .distantPast,
            modified: attributes?[.modificationDate] as? Date ?? .distantPast, size: text.utf8.count
        )
        let types = propertyTypes?.recorded ?? [:]
        var result: [String: PropertySchema] = [:]
        for base in bases where !base.schemas.isEmpty && base.contains(note, types: types) {
            for (id, schema) in base.schemas where id.hasPrefix("note.") {
                let key = String(id.dropFirst(5))
                if result[key] == nil { result[key] = schema }
            }
        }
        return result
    }

    private func base(at url: URL) -> BaseFile? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let cached = baseCache[url.path], cached.modified == modified { return cached.base }
        let base = (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? BaseFile(yaml: $0) }
        baseCache[url.path] = (modified, base)
        return base
    }

    /// vault のノートをすべて読む（`.base` の表に使う）。書きかけの変更は先に保存する
    func noteRecords() async -> [NoteRecord] {
        guard let root else { return [] }
        saveNow()
        let urls = FileNode.notes(in: tree)
        return await Task.detached { NoteRecord.load(urls, root: root) }.value
    }

    /// 隠しファイル（.obsidian や .git）を除き、フォルダと .md・.base だけを集める
    nonisolated static func scan(_ dir: URL) -> [FileNode] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        var nodes: [FileNode] = []
        for url in items {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                let children = scan(url)
                if !children.isEmpty {
                    nodes.append(FileNode(url: url, isDirectory: true, children: children))
                }
            } else if ["md", "base"].contains(url.pathExtension.lowercased()) {
                nodes.append(FileNode(url: url, isDirectory: false))
            }
        }
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

extension FileNode: @unchecked Sendable {
    var isBase: Bool { !isDirectory && url.pathExtension.lowercased() == "base" }

    /// ツリーの中のファイル（.md と .base）を並べる
    static func files(in nodes: [FileNode]) -> [URL] {
        nodes.flatMap { $0.isDirectory ? files(in: $0.children) : [$0.url] }
    }

    /// ツリーの中のノート（.md）を並べる
    static func notes(in nodes: [FileNode]) -> [URL] {
        nodes.flatMap { $0.isDirectory ? notes(in: $0.children) : $0.isBase ? [] : [$0.url] }
    }
}
