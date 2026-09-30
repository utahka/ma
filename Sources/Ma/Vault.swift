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

    var onTreeChange: (() -> Void)?
    /// タブの並び・選択中のタブ・タブで開いているファイルが変わったとき
    var onTabsChange: (() -> Void)?
    /// タブにノートを読み込んだとき（nil は空のタブ）
    var onLoad: ((Tab.ID, OpenDocument?) -> Void)?
    /// vault を開いたときとデイリーノートを作ったとき（カレンダーの点を打ち直す）
    var onNotesChange: (() -> Void)?

    private var pendingTexts: [URL: String] = [:]
    private var saveTask: Task<Void, Never>?
    /// 中身を読み込み済みのタブ。復元したタブは選ばれたときに読む
    private var loadedTabs: Set<Tab.ID> = []
    /// 次回の起動で開く vault のときだけ、開いているタブも記録する
    private var remembersTabs = false

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
        onTreeChange?()
        tabsDidChange()
        onNotesChange?()
        if remember { AppDefaults.shared.set(url.path, forKey: Self.lastRootKey) }
        rescan()
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

extension FileNode: @unchecked Sendable {}
