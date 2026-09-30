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
}

/// タブ。`url` が nil のときは何も開いていない新しいタブ
struct Tab: Identifiable {
    let id = UUID()
    var url: URL?

    var title: String { url?.deletingPathExtension().lastPathComponent ?? "新しいタブ" }
}

/// 開いているフォルダ（vault）と、タブで開いているノートの読み書きを受け持つ
@MainActor
final class Vault {
    private(set) var root: URL?
    private(set) var tree: [FileNode] = []
    private(set) var dailyNotes: DailyNotes?
    /// 同じファイルを2つのタブで開くことはない（開こうとしたらそのタブに切り替える）
    private(set) var tabs = [Tab()]
    private(set) var activeIndex = 0
    var activeTab: Tab { tabs[activeIndex] }
    private(set) var bookmarks: [Bookmark] = []

    var onTreeChange: (() -> Void)?
    /// タブの並び・選択中のタブ・タブで開いているファイルが変わったとき
    var onTabsChange: (() -> Void)?
    /// タブにノートを読み込んだとき（nil は空のタブ）
    var onLoad: ((Tab.ID, OpenDocument?) -> Void)?
    /// vault を開いたときとデイリーノートを作ったとき（カレンダーの点を打ち直す）
    var onNotesChange: (() -> Void)?
    var onBookmarksChange: (() -> Void)?

    private var pendingTexts: [URL: String] = [:]
    private var saveTask: Task<Void, Never>?
    /// 中身を読み込み済みのタブ。復元したタブは選ばれたときに読む
    private var loadedTabs: Set<Tab.ID> = []
    /// 次回の起動で開く vault のときだけ、開いているタブも記録する
    private var remembersTabs = false
    /// 最後に読んだ bookmarks.json の中身（nil はファイルがない）。変わっていなければ読み直さない
    private var bookmarksData: Data?
    private var bookmarksLoaded = false

    private static let lastRootKey = "lastRoot"
    private static let tabsKey = "openTabs"
    private static let activeTabKey = "activeTab"

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
        saveNow()
        root = url
        tree = []
        dailyNotes = DailyNotes(root: url)
        remembersTabs = remember
        tabs = [Tab()]
        activeIndex = 0
        loadedTabs = []
        bookmarks = []
        bookmarksLoaded = false
        onTreeChange?()
        tabsDidChange()
        onNotesChange?()
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
        onBookmarksChange?()
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

    /// 表示中のブックマークを外す。表示した後にファイルが変わっていたら位置がずれるので、読み直すだけにする
    func removeBookmark(at indexPath: [Int]) {
        updateBookmarks(requiresUnchanged: true) { Bookmarks.removing(at: indexPath, from: $0) }
    }

    private func updateBookmarks(requiresUnchanged: Bool = false, _ change: ([Any]) -> [Any]) {
        guard let root else { return }
        guard var (document, data) = Bookmarks.readDocument(root: root) else {
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
    private func relativePath(of url: URL) -> String? {
        guard let root, url.path.hasPrefix(root.path + "/") else { return nil }
        return String(url.path.dropFirst(root.path.count + 1)).precomposedStringWithCanonicalMapping
    }

    private func rescan() {
        guard let url = root else { return }
        Task {
            let scanned = await Task.detached { Self.scan(url) }.value
            guard root == url else { return }
            tree = scanned
            onTreeChange?()
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
            onNotesChange?()
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
        saveNow()
        if newTab, activeTab.url != nil {
            activeIndex += 1
            tabs.insert(Tab(url: url), at: activeIndex)
        } else {
            tabs[activeIndex].url = url
            loadedTabs.remove(activeTab.id)
        }
        tabsDidChange()
    }

    func newTab() {
        activeIndex += 1
        tabs.insert(Tab(), at: activeIndex)
        tabsDidChange()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else { return }
        activeIndex = index
        tabsDidChange()
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
                    onLoad?(tab.id, OpenDocument(url: url, text: try String(contentsOf: url, encoding: .utf8)))
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
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("保存に失敗: \(url.path): \(error)")
            }
        }
        pendingTexts = [:]
    }

    /// 隠しファイル（.obsidian や .git）を除き、フォルダと .md だけを集める
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
            } else if url.pathExtension.lowercased() == "md" {
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
    /// ツリーの中のノートを並べる
    static func notes(in nodes: [FileNode]) -> [URL] {
        nodes.flatMap { $0.isDirectory ? notes(in: $0.children) : [$0.url] }
    }
}
