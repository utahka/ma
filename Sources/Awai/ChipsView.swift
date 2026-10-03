import AppKit

/// セレクト・ステータスの値を、色付きの角丸のチップとして横に並べて描く
final class ChipsView: NSView {
    struct Chip: Equatable {
        let label: String
        let color: NSColor
    }

    var chips: [Chip] = [] { didSet { if chips != oldValue { needsDisplay = true } } }
    /// チップがないときに薄く出す文字
    var placeholder: String? { didSet { needsDisplay = true } }
    /// クリックされたとき（プロパティ欄で選択肢のメニューを出す）
    var onClick: ((ChipsView) -> Void)?

    static let font = NSFont.systemFont(ofSize: 12)
    private static let height: CGFloat = 20

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let top = (bounds.height - Self.height) / 2
        guard !chips.isEmpty else {
            if let placeholder {
                let text = NSAttributedString(string: placeholder, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
                text.draw(at: NSPoint(x: 0, y: (bounds.height - text.size().height) / 2))
            }
            return
        }
        var x: CGFloat = 0
        for chip in chips {
            let text = NSAttributedString(string: chip.label, attributes: [.font: Self.font, .foregroundColor: NSColor.maText])
            let size = text.size()
            let width = ceil(size.width) + 14
            // 収まらない分は描かない
            guard x + width <= bounds.width || x == 0 else { break }
            let rect = NSRect(x: x, y: top, width: min(width, bounds.width), height: Self.height)
            chip.color.withAlphaComponent(effectiveAppearance.isDark ? 0.35 : 0.22).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            text.draw(with: NSRect(x: x + 7, y: top + (Self.height - size.height) / 2, width: rect.width - 14, height: size.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            x += width + 4
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick(self) } else { super.mouseDown(with: event) }
    }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// 色の名前（`.base` の `color`）を色にする
    nonisolated static func color(named name: String) -> NSColor {
        switch name {
        case "red": .systemRed
        case "orange": .systemOrange
        case "yellow": .systemYellow
        case "green": .systemGreen
        case "blue": .systemBlue
        case "purple": .systemPurple
        case "pink": .systemPink
        case "brown": .systemBrown
        default: .systemGray
        }
    }
}

extension PropertySchema {
    /// 値のチップ。選択肢にない値は灰色にし、元の文字のまま見せる（データの揺れに気づけるように）
    func chip(for value: String) -> ChipsView.Chip {
        guard let option = option(for: value) else { return ChipsView.Chip(label: value, color: .systemGray) }
        return ChipsView.Chip(label: option.label, color: ChipsView.color(named: option.color))
    }

    func chips(for value: BaseValue) -> [ChipsView.Chip] {
        switch value {
        case .list(let items): items.map { chip(for: $0.text) }
        case .null: []
        default: value.isEmpty ? [] : [chip(for: value.text)]
        }
    }

    /// 選択肢のメニュー。選んだら新しい値を `choose` に渡す。マルチセレクトは選ぶたびに付け外しし、付け外しした後のリストを渡す
    @MainActor
    func optionsMenu(for value: PropertyValue, choose: @escaping (PropertyValue) -> Void) -> NSMenu {
        var current: [String]
        switch value {
        case .list(let items): current = items
        case .scalar(let text) where !text.isEmpty: current = [text]
        default: current = []
        }
        // 値がなければ既定値が入っているものとして印を付ける
        let checked = current.isEmpty && kind != .multiSelect ? (defaultValue.map { [$0] } ?? []) : current
        func pick(_ picked: String) {
            if kind == .multiSelect {
                var items = current
                if let index = items.firstIndex(of: picked) { items.remove(at: index) } else { items.append(picked) }
                choose(.list(items))
            } else {
                choose(.scalar(picked))
            }
        }
        let menu = NSMenu()
        for option in options {
            let item = ActionMenuItem(title: option.label) { pick(option.value) }
            item.image = dot(for: option)
            item.state = checked.contains(option.value) ? .on : .off
            menu.addItem(item)
        }
        // 選択肢にない値も、今入っているなら外せるように出す
        for value in current where option(for: value) == nil {
            let item = ActionMenuItem(title: value) { pick(value) }
            item.state = .on
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: "選択肢がありません", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if kind == .select, !current.isEmpty {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(title: "クリア") { choose(.scalar("")) })
        }
        return menu
    }

    /// メニューの項目に付ける色の丸
    func dot(for option: Option) -> NSImage {
        let color = ChipsView.color(named: option.color)
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// 選んだときにクロージャを呼ぶメニューの項目
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
