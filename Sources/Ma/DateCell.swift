import AppKit

/// 日付・日時のプロパティの値。押すとカレンダーのポップオーバーを出し、選んだ日付を `onChange` に渡す（空文字はクリア）
final class DateCell: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var includesTime = false
    /// 値がないときの薄い文字。表では出さない
    var placeholder: String? = "空"
    var onChange: ((String) -> Void)?
    private var popover: NSPopover?

    static let font = NSFont.systemFont(ofSize: 13)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let empty = text.isEmpty
        guard !empty || placeholder != nil else { return }
        let string = NSAttributedString(string: empty ? placeholder ?? "" : text, attributes: [
            .font: Self.font, .foregroundColor: empty ? NSColor.placeholderTextColor : NSColor.maText,
        ])
        string.draw(at: NSPoint(x: 0, y: (bounds.height - string.size().height) / 2))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = includesTime ? [.yearMonthDay, .hourMinute] : [.yearMonthDay]
        picker.dateValue = Self.parse(text) ?? Date()
        picker.target = self
        picker.action = #selector(pick(_:))
        picker.sizeToFit()

        let clear = NSButton(title: "クリア", target: self, action: #selector(clearValue))
        clear.bezelStyle = .push
        clear.controlSize = .small
        let today = NSButton(title: "今日", target: self, action: #selector(pickToday))
        today.bezelStyle = .push
        today.controlSize = .small
        let buttons = NSStackView(views: [today, clear])
        let stack = NSStackView(views: [picker, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }

    @objc private func pick(_ sender: NSDatePicker) {
        commit(Self.format(sender.dateValue, includesTime: includesTime))
        // 日付だけのときは選んだら閉じる。時刻もあるときは時刻を合わせられるよう開いたままにする
        if !includesTime { popover?.close() }
    }

    @objc private func pickToday() {
        commit(Self.format(Date(), includesTime: includesTime))
        popover?.close()
    }

    @objc private func clearValue() {
        commit("")
        popover?.close()
    }

    private func commit(_ value: String) {
        guard value != text else { return }
        text = value
        onChange?(value)
    }

    // MARK: - 書式

    /// Obsidian と同じ形（`2026-09-30`、日時は `2026-09-30T14:00`）
    static func format(_ date: Date, includesTime: Bool) -> String {
        formatter(includesTime ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd").string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            if let date = formatter(pattern).date(from: trimmed) { return date }
        }
        return nil
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }
}
