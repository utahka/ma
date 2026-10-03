import AppKit

/// AppKit のタイトルバー配置を終えてから、描画前に信号機の位置を揃える。
final class AwaiWindow: NSWindow {
    var onLayout: (() -> Void)?
    private(set) var isPlacingTrafficLights = false

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        guard !isPlacingTrafficLights else { return }
        isPlacingTrafficLights = true
        defer { isPlacingTrafficLights = false }
        onLayout?()
    }
}
