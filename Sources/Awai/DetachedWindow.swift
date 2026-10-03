import AppKit

/// タブをウィンドウの外へドラッグして作る、サイドバーのないウィンドウ（Obsidian の分離ウィンドウと同じ）。
/// タブと履歴はこのウィンドウの `Vault` が持ち、フォルダ・ファイル一覧・お気に入り・保存待ちの本文はメインウィンドウと共有する。
/// エディタとタブの結び付けは `AppDelegate` がメインウィンドウと同じ処理で行う
@MainActor
final class DetachedWindow: NSObject, NSWindowDelegate {
    let vault: Vault
    let editor = EditorAreaViewController()
    let window: NSWindow
    var onClose: ((DetachedWindow) -> Void)?

    init(vault: Vault, frame: NSRect) {
        self.vault = vault
        window = AwaiWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()
        // 閉じたあとも持ち主が参照を外すまで残す
        window.isReleasedWhenClosed = false
        editor.view.frame = NSRect(origin: .zero, size: frame.size)
        window.contentViewController = editor
        window.contentMinSize = NSSize(width: 480, height: 320)
        // contentViewController を設定するとビューの最小サイズまで縮むので、設定後に大きさと位置を戻す
        window.setFrame(window.constrainFrameRect(frame, to: NSScreen.screens.first { $0.frame.intersects(frame) }), display: false)
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        vault.leaveFolder()
        onClose?(self)
    }
}
