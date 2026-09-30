import AppKit

/// エディタの上端（タイトルバーの位置）に並べるタブ。Chrome のように、選択中のタブだけ本文と同じ色にしてつなげる。
/// クリックで選択、× か中クリックで閉じる、ドラッグで並べ替え、何もないところのドラッグでウィンドウを動かす
final class TabBarView: NSView {
    static let height: CGFloat = 34

    var titles: [String] = [] { didSet { needsDisplay = true } }
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onNewTab: (() -> Void)?

    private let maxTabWidth: CGFloat = 220
    private let minTabWidth: CGFloat = 60
    private let tabTop: CGFloat = 6
    private let cornerRadius: CGFloat = 7
    private let buttonSize: CGFloat = 18

    private enum Target: Equatable {
        case tab(Int), close(Int), newTab
    }
    private var hovered: Target?
    private var pressed: Target?
    private struct Drag {
        var index: Int
        let startX: CGFloat
        var offset: CGFloat = 0
        var moved = false
    }
    private var drag: Drag?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - 位置

    /// サイドバーを閉じているときは信号機ボタンの右から並べる
    private var leadingInset: CGFloat {
        guard let window, !window.styleMask.contains(.fullScreen),
              let zoom = window.standardWindowButton(.zoomButton), let buttons = zoom.superview
        else { return 8 }
        let buttonsEnd = buttons.convert(zoom.frame, to: nil).maxX + 12
        return max(8, buttonsEnd - convert(NSPoint.zero, to: nil).x)
    }

    private var tabWidth: CGFloat {
        guard !titles.isEmpty else { return maxTabWidth }
        let available = bounds.width - leadingInset - buttonSize - 16
        return min(maxTabWidth, max(minTabWidth, available / CGFloat(titles.count)))
    }

    private func tabRect(_ index: Int) -> CGRect {
        var rect = CGRect(x: leadingInset + CGFloat(index) * tabWidth, y: tabTop, width: tabWidth, height: bounds.height - tabTop)
        if let drag, drag.index == index { rect.origin.x += drag.offset }
        return rect
    }

    private func closeRect(_ index: Int) -> CGRect {
        let tab = tabRect(index)
        return CGRect(x: tab.maxX - buttonSize - 6, y: tab.midY - buttonSize / 2, width: buttonSize, height: buttonSize)
    }

    private var newTabRect: CGRect {
        let x = leadingInset + CGFloat(titles.count) * tabWidth + 6
        let midY = tabTop + (bounds.height - tabTop) / 2
        return CGRect(x: x, y: midY - buttonSize / 2, width: buttonSize, height: buttonSize)
    }

    /// × は選択中のタブと、マウスが乗っているタブにだけ出す
    private func showsClose(_ index: Int) -> Bool {
        index == selectedIndex || hovered == .tab(index) || hovered == .close(index)
    }

    private func target(at point: NSPoint) -> Target? {
        if newTabRect.contains(point) { return .newTab }
        for index in titles.indices where tabRect(index).contains(point) {
            // マウスが乗ったタブには × が出るので、位置だけで判定する
            return closeRect(index).insetBy(dx: -2, dy: -2).contains(point) ? .close(index) : .tab(index)
        }
        return nil
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        for index in titles.indices where index != selectedIndex && index != drag?.index {
            drawTab(index)
        }
        if titles.indices.contains(selectedIndex), selectedIndex != drag?.index { drawTab(selectedIndex) }
        if let drag { drawTab(drag.index) }
        drawButton(in: newTabRect, highlighted: hovered == .newTab, symbol: "plus")
    }

    private func drawTab(_ index: Int) {
        let rect = tabRect(index)
        let selected = index == selectedIndex
        if selected {
            NSColor.textBackgroundColor.setFill()
            selectedTabPath(rect).fill()
        } else if hovered == .tab(index) || hovered == .close(index) {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 0).insetBy(dx: 0, dy: 3).offsetBy(dx: 0, dy: -2),
                         xRadius: 6, yRadius: 6).fill()
        } else if index + 1 != selectedIndex, index + 1 < titles.count, drag == nil,
                  hovered != .tab(index + 1), hovered != .close(index + 1) {
            // 隣り合う選択していないタブの間の仕切り
            NSColor.separatorColor.setFill()
            CGRect(x: rect.maxX - 0.5, y: rect.midY - 8, width: 1, height: 16).fill()
        }

        let showsClose = showsClose(index)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: selected ? NSColor.maText : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let title = NSAttributedString(string: titles[index], attributes: attributes)
        let textHeight = title.size().height
        let right = showsClose ? closeRect(index).minX - 4 : rect.maxX - 12
        title.draw(with: CGRect(x: rect.minX + 12, y: rect.midY - textHeight / 2, width: max(0, right - rect.minX - 12), height: textHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        if showsClose {
            drawButton(in: closeRect(index), highlighted: hovered == .close(index), symbol: "xmark")
        }
    }

    /// 上の角を丸め、下の両端は外へ反らせて本文とつなげる
    private func selectedTabPath(_ rect: CGRect) -> NSBezierPath {
        let r = cornerRadius
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX - r, y: rect.maxY))
        path.appendArc(withCenter: CGPoint(x: rect.minX - r, y: rect.maxY - r), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.appendArc(withCenter: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: 180, endAngle: 270)
        path.line(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.appendArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 270, endAngle: 0)
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.appendArc(withCenter: CGPoint(x: rect.maxX + r, y: rect.maxY - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        path.close()
        return path
    }

    private func drawButton(in rect: CGRect, highlighted: Bool, symbol: String) {
        if highlighted {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: symbol == "plus" ? 11 : 9, weight: .semibold)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    // MARK: - マウス

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(target(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ target: Target?) {
        guard target != hovered else { return }
        hovered = target
        needsDisplay = true
        if case .tab(let index) = target { toolTip = titles[index] } else { toolTip = nil }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch target(at: point) {
        case .tab(let index)?:
            onSelect?(index)
            drag = Drag(index: index, startX: point.x)
        case let target?:
            pressed = target
        case nil:
            if event.clickCount == 2 {
                performTitlebarDoubleClick()
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag else { return }
        let x = convert(event.locationInWindow, from: nil).x
        drag.offset = x - drag.startX
        if abs(drag.offset) > 3 { drag.moved = true }
        guard drag.moved else { return }
        // ドラッグ中のタブの中心が隣のタブの位置に入ったら入れ替える
        let center = leadingInset + (CGFloat(drag.index) + 0.5) * tabWidth + drag.offset
        let destination = min(max(Int((center - leadingInset) / tabWidth), 0), titles.count - 1)
        let source = drag.index
        if destination != source {
            // 入れ替えた先の位置を起点にし直し、タブがマウスの下に留まるようにする
            let shift = CGFloat(destination - source) * tabWidth
            drag = Drag(index: destination, startX: drag.startX + shift, offset: drag.offset - shift, moved: true)
        }
        self.drag = drag
        if destination != source { onMove?(source, destination) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let pressed, target(at: point) == pressed {
            switch pressed {
            case .close(let index): onClose?(index)
            case .newTab: onNewTab?()
            case .tab: break
            }
        }
        pressed = nil
        drag = nil
        setHovered(target(at: point))
        needsDisplay = true
    }

    /// 中クリックで閉じる
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2,
              case .tab(let index)? = target(at: convert(event.locationInWindow, from: nil))
        else { return super.otherMouseUp(with: event) }
        onClose?(index)
    }

    /// システム設定の「タイトルバーをダブルクリックして…」に従う
    private func performTitlebarDoubleClick() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.performMiniaturize(nil)
        case "None": break
        default: window?.performZoom(nil)
        }
    }
}
