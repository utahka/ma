import AppKit

/// エディタの上端（タイトルバーの位置）に並べるタブ。Chrome のように、選択中のタブだけ本文と同じ色にしてつなげる。
/// クリックで選択、× か中クリックで閉じる、ドラッグで並べ替え、何もないところのドラッグでウィンドウを動かす。
/// タブをウィンドウの外までドラッグして離すと、別のウィンドウに分離する（タブが2つ以上あるときだけ）。
/// 左端には選択中のタブの「戻る」「進む」を置く
final class TabBarView: NSView {
    static let height: CGFloat = 34

    var titles: [String] = [] { didSet { needsDisplay = true } }
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    /// タブをウィンドウの外で離したとき（タブの位置、離した位置の画面座標）
    var onDetach: ((Int, NSPoint) -> Void)?
    var onNewTab: (() -> Void)?
    var canGoBack = false { didSet { needsDisplay = true } }
    var canGoForward = false { didSet { needsDisplay = true } }
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    /// サイドバーを閉じているときは、左端にサイドバーを開くボタンを出す
    var showsSidebarButton = false { didSet { needsDisplay = true } }
    var onToggleSidebar: (() -> Void)?

    private let maxTabWidth: CGFloat = 220
    private let minTabWidth: CGFloat = 60
    private let tabTop: CGFloat = 6
    private let cornerRadius: CGFloat = 7
    private let buttonSize: CGFloat = 18

    private enum Target: Equatable {
        case tab(Int), close(Int), newTab, back, forward, sidebar
    }
    private var hovered: Target?
    private var pressed: Target?
    private struct Drag {
        var index: Int
        let startX: CGFloat
        var offset: CGFloat = 0
        var moved = false
        /// ウィンドウの外にいる（離すと分離する）
        var outside = false
    }
    private var drag: Drag?
    /// ウィンドウの外までドラッグしている間、マウスに付いてくるタブの絵
    private var dragPreview: NSWindow?
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

    private var midY: CGFloat { tabTop + (bounds.height - tabTop) / 2 }

    /// 信号機ボタンのすぐ右（フルスクリーンでは信号機ボタンがないので左端）に置く
    private var sidebarRect: CGRect? {
        guard showsSidebarButton else { return nil }
        let width = TrafficLights.sidebarToggleWidth
        return CGRect(x: leadingInset, y: midY - width / 2, width: width, height: width)
    }

    private var backRect: CGRect {
        let x = sidebarRect.map { $0.maxX + 8 } ?? leadingInset
        return CGRect(x: x, y: midY - buttonSize / 2, width: buttonSize, height: buttonSize)
    }

    private var forwardRect: CGRect { backRect.offsetBy(dx: buttonSize + 4, dy: 0) }

    /// 最初のタブの左端
    private var tabsStart: CGFloat { forwardRect.maxX + 8 }

    private var tabWidth: CGFloat {
        guard !titles.isEmpty else { return maxTabWidth }
        let available = bounds.width - tabsStart - buttonSize - 16
        return min(maxTabWidth, max(minTabWidth, available / CGFloat(titles.count)))
    }

    private func tabRect(_ index: Int) -> CGRect {
        var rect = CGRect(x: tabsStart + CGFloat(index) * tabWidth, y: tabTop, width: tabWidth, height: bounds.height - tabTop)
        if let drag, drag.index == index { rect.origin.x += drag.offset }
        return rect
    }

    private func closeRect(_ index: Int) -> CGRect {
        let tab = tabRect(index)
        return CGRect(x: tab.maxX - buttonSize - 6, y: tab.midY - buttonSize / 2, width: buttonSize, height: buttonSize)
    }

    private var newTabRect: CGRect {
        let x = tabsStart + CGFloat(titles.count) * tabWidth + 6
        return CGRect(x: x, y: midY - buttonSize / 2, width: buttonSize, height: buttonSize)
    }

    /// × は選択中のタブと、マウスが乗っているタブにだけ出す
    private func showsClose(_ index: Int) -> Bool {
        index == selectedIndex || hovered == .tab(index) || hovered == .close(index)
    }

    private func target(at point: NSPoint) -> Target? {
        if newTabRect.contains(point) { return .newTab }
        if sidebarRect?.contains(point) == true { return .sidebar }
        if backRect.contains(point) { return .back }
        if forwardRect.contains(point) { return .forward }
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
        if let sidebarRect { drawSidebarButton(in: sidebarRect, highlighted: hovered == .sidebar) }
        drawButton(in: backRect, highlighted: canGoBack && hovered == .back, symbol: "chevron.left", enabled: canGoBack)
        drawButton(in: forwardRect, highlighted: canGoForward && hovered == .forward, symbol: "chevron.right", enabled: canGoForward)
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

    private func drawButton(in rect: CGRect, highlighted: Bool, symbol: String, enabled: Bool = true) {
        if highlighted {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        let pointSize: CGFloat = switch symbol {
        case "plus", "chevron.left", "chevron.right": 11
        default: 9
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(.init(hierarchicalColor: enabled ? .secondaryLabelColor : .quaternaryLabelColor))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    /// サイドバーのボタンと同じ、枠を持たない template 画像を同じ色で描き、縦の位置と見た目を揃える
    private func drawSidebarButton(in rect: CGRect, highlighted: Bool) {
        if highlighted {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        let symbol = SidebarViewController.centeredSymbol("sidebar.left", label: "サイドバーを開く")
        let size = symbol.size
        let tinted = NSImage(size: size, flipped: false) { bounds in
            // 色で塗ってから絵の形に切り抜く（絵の上から塗ると、半透明の色に下の黒が透けて濃くなる）
            NSColor.secondaryLabelColor.setFill()
            bounds.fill()
            symbol.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        tinted.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
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
        switch target {
        case .tab(let index)?: toolTip = titles[index]
        case .sidebar?: toolTip = "サイドバーを開く"
        case .back?: toolTip = "戻る"
        case .forward?: toolTip = "進む"
        default: toolTip = nil
        }
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
        // ウィンドウの外ではタブの絵をマウスに付けて、並べ替えはしない
        let outside = canDetach && window.map { !$0.frame.contains(NSEvent.mouseLocation) } == true
        if outside != drag.outside {
            drag.outside = outside
            if outside { showDragPreview(for: drag.index) } else { hideDragPreview() }
        }
        if outside {
            moveDragPreview()
            self.drag = drag
            needsDisplay = true
            return
        }
        // ドラッグ中のタブの中心が隣のタブの位置に入ったら入れ替える
        let center = tabsStart + (CGFloat(drag.index) + 0.5) * tabWidth + drag.offset
        let destination = min(max(Int((center - tabsStart) / tabWidth), 0), titles.count - 1)
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
        hideDragPreview()
        if let drag, drag.outside, canDetach {
            self.drag = nil
            needsDisplay = true
            onDetach?(drag.index, NSEvent.mouseLocation)
            return
        }
        if let pressed, target(at: point) == pressed {
            switch pressed {
            case .close(let index): onClose?(index)
            case .newTab: onNewTab?()
            case .sidebar: onToggleSidebar?()
            case .back: if canGoBack { onBack?() }
            case .forward: if canGoForward { onForward?() }
            case .tab: break
            }
        }
        pressed = nil
        drag = nil
        setHovered(target(at: point))
        needsDisplay = true
    }

    // MARK: - 分離

    /// タブが1つだけのウィンドウからは分離しない（Obsidian と同じ）
    private var canDetach: Bool { onDetach != nil && titles.count > 1 }

    private func showDragPreview(for index: Int) {
        let image = dragImage(for: index)
        let preview = NSWindow(contentRect: CGRect(origin: .zero, size: image.size), styleMask: .borderless,
                               backing: .buffered, defer: false)
        preview.isReleasedWhenClosed = false
        preview.isOpaque = false
        preview.backgroundColor = .clear
        preview.hasShadow = true
        preview.level = .floating
        preview.ignoresMouseEvents = true
        let imageView = NSImageView(image: image)
        imageView.frame = CGRect(origin: .zero, size: image.size)
        preview.contentView = imageView
        dragPreview = preview
        moveDragPreview()
        preview.orderFront(nil)
    }

    /// タブの左寄りをマウスの下に置く
    private func moveDragPreview() {
        guard let dragPreview else { return }
        let mouse = NSEvent.mouseLocation
        dragPreview.setFrameOrigin(NSPoint(x: mouse.x - 24, y: mouse.y - dragPreview.frame.height / 2))
    }

    private func hideDragPreview() {
        dragPreview?.orderOut(nil)
        dragPreview = nil
    }

    /// 選択中のタブと同じ見た目の、角を丸めたタブの絵
    private func dragImage(for index: Int) -> NSImage {
        let size = CGSize(width: tabWidth, height: bounds.height - tabTop)
        let title = titles[index]
        return NSImage(size: size, flipped: true) { rect in
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.maText, .paragraphStyle: paragraph,
            ])
            let height = text.size().height
            text.draw(with: CGRect(x: 12, y: rect.midY - height / 2, width: rect.width - 24, height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
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
