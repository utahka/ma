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
