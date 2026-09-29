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

/// エディタに渡す開いているノート
struct OpenDocument {
    let url: URL
    let text: String
}

/// 開いているフォルダ（vault）と、選択中のノートの読み書きを受け持つ
@MainActor
final class Vault {
    private(set) var root: URL?
    private(set) var tree: [FileNode] = []
    private(set) var document: OpenDocument?

    var onTreeChange: (() -> Void)?
    var onDocumentChange: (() -> Void)?

    private var pendingText: String?
    private var saveTask: Task<Void, Never>?

    private static let lastRootKey = "lastRoot"

    func restoreLastRoot() {
        if let path = UserDefaults.standard.string(forKey: Self.lastRootKey),
           FileManager.default.fileExists(atPath: path) {
            setRoot(URL(fileURLWithPath: path, isDirectory: true))
        }
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

    func setRoot(_ url: URL) {
        saveNow()
        root = url
        tree = []
        document = nil
        onTreeChange?()
        onDocumentChange?()
        UserDefaults.standard.set(url.path, forKey: Self.lastRootKey)
        Task {
            let scanned = await Task.detached { Self.scan(url) }.value
            guard root == url else { return }
            tree = scanned
            onTreeChange?()
        }
    }

    func open(_ url: URL) {
        guard url != document?.url else { return }
        saveNow()
        do {
            document = OpenDocument(url: url, text: try String(contentsOf: url, encoding: .utf8))
            onDocumentChange?()
        } catch {
            NSLog("読み込みに失敗: \(url.path): \(error)")
        }
    }

    /// 編集のたびに呼ばれる。0.5 秒入力が止まったら保存する
    func textDidChange(_ text: String) {
        pendingText = text
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
        guard let document, let text = pendingText else { return }
        pendingText = nil
        do {
            try text.write(to: document.url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("保存に失敗: \(document.url.path): \(error)")
        }
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
