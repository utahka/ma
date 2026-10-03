import AppKit

/// AI へのコメントを付けた文字にマウスを乗せたとき、コメント本文を出す吹き出し。
/// ツールチップは出るまで遅いので、ポップオーバーをすぐに出す。開閉は EditorTextView が受け持つ
@MainActor
final class AICommentPopover {
    private let popover = NSPopover()
    private let label = NSTextField(wrappingLabelWithString: "")
    /// 表示中のコメントを付けた文字の範囲（文書内）
    private(set) var range: NSRange?
    private let container = NSView()
    private let maxWidth: CGFloat = 280
    private let padding = NSSize(width: 10, height: 7)

    init() {
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.isSelectable = false
        container.addSubview(label)
        let controller = NSViewController()
        controller.view = container
        popover.contentViewController = controller
        // 閉じるのは EditorTextView が決める。出し入れが頻繁なのでアニメーションはしない
        popover.behavior = .applicationDefined
        popover.animates = false
    }

    /// `rect`（`view` の座標）の上にコメントを出す。同じ範囲を出しているあいだは何もしない
    func show(_ comment: String, for range: NSRange, relativeTo rect: NSRect, of view: NSView) {
        if popover.isShown, self.range == range { return }
        label.stringValue = comment
        self.range = range
        // 短いコメントは文字の幅に合わせ、長いコメントは最大幅で折り返す。
        // 制約の fittingSize では大きさが 0 のまま出たので、文字の大きさを測って置く
        let size = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth, height: .greatestFiniteMagnitude)) ?? .zero
        let textSize = NSSize(width: ceil(min(size.width, maxWidth)), height: ceil(size.height))
        label.frame = NSRect(origin: NSPoint(x: padding.width, y: padding.height), size: textSize)
        popover.contentSize = NSSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
    }

    func close() {
        range = nil
        if popover.isShown { popover.close() }
    }
}
