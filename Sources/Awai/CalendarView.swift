import AppKit

/// Obsidian の Calendar プラグインに相当する月のカレンダー。
/// デイリーノートのある日に点を1つ打ち、日付を押すと `onSelectDate` を呼ぶ
final class CalendarView: NSView {
    var onSelectDate: ((Date) -> Void)?

    /// その日のデイリーノートがあるかを返す。nil のあいだは点を描かない
    var hasNote: ((Date) -> Bool)? { didSet { reloadDots() } }
    var firstWeekday = Calendar.current.firstWeekday { didSet { needsDisplay = true } }
    /// 開いているノートの日付
    var selectedDate: Date? { didSet { needsDisplay = true } }

    private var calendar = Calendar(identifier: .gregorian)
    private var month: Date
    private var daysWithNote: Set<Date> = []
    private var hoveredDay: Date?

    private let titleLabel = NSTextField(labelWithString: "")
    private let headerHeight: CGFloat = 30
    private let weekdayHeight: CGFloat = 20
    private let rowHeight: CGFloat = 28
    private let inset: CGFloat = 8

    static let preferredHeight: CGFloat = 30 + 20 + 28 * 6 + 8

    override init(frame: NSRect) {
        calendar.locale = Locale(identifier: "ja_JP")
        month = calendar.dateInterval(of: .month, for: Date())!.start
        super.init(frame: frame)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .maText
        let previous = makeButton(symbol: "chevron.left", label: "前の月", action: #selector(showPreviousMonth))
        let next = makeButton(symbol: "chevron.right", label: "次の月", action: #selector(showNextMonth))
        let today = NSButton(title: "今日", target: self, action: #selector(showToday))
        today.bezelStyle = .accessoryBarAction
        today.showsBorderOnlyWhileMouseInside = true
        today.controlSize = .small
        today.font = .systemFont(ofSize: 11)
        for view in [titleLabel, previous, today, next] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 4),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: headerHeight / 2 + 2),
            next.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            next.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            today.trailingAnchor.constraint(equalTo: next.leadingAnchor, constant: -2),
            today.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            previous.trailingAnchor.constraint(equalTo: today.leadingAnchor, constant: -2),
            previous.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        updateTitle()

        // 日付が変わったら「今日」の印を動かす
        NotificationCenter.default.addObserver(
            self, selector: #selector(dayDidChange), name: .NSCalendarDayChanged, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func makeButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.controlSize = .small
        button.toolTip = label
        return button
    }

    /// ノートを作ったあとに点を打ち直す
    func reloadDots() {
        daysWithNote = hasNote.map { hasNote in Set(visibleDays().filter(hasNote)) } ?? []
        needsDisplay = true
    }

    /// 指定した日を含む月を表示する
    func show(month date: Date) {
        let start = calendar.dateInterval(of: .month, for: date)!.start
        guard start != month else { return }
        month = start
        updateTitle()
        reloadDots()
    }

    @objc private func showPreviousMonth() { show(month: calendar.date(byAdding: .month, value: -1, to: month)!) }
    @objc private func showNextMonth() { show(month: calendar.date(byAdding: .month, value: 1, to: month)!) }
    @objc private func showToday() { show(month: Date()) }
    /// NSCalendarDayChanged はバックグラウンドのキューから届く。メインアクターの検査で落ちないよう nonisolated で受ける
    @objc nonisolated private func dayDidChange() { Task { @MainActor in self.needsDisplay = true } }

    private func updateTitle() {
        let components = calendar.dateComponents([.year, .month], from: month)
        titleLabel.stringValue = "\(components.year!)年\(components.month!)月"
    }

    /// 表示する 6 週ぶんの日付（前後の月を含む）
    private func visibleDays() -> [Date] {
        let weekday = calendar.component(.weekday, from: month)
        let leading = (weekday - firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -leading, to: month)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    private var columnWidth: CGFloat { (bounds.width - inset * 2) / 7 }

    private func cellRect(index: Int) -> NSRect {
        NSRect(
            x: inset + CGFloat(index % 7) * columnWidth,
            y: headerHeight + weekdayHeight + CGFloat(index / 7) * rowHeight,
            width: columnWidth, height: rowHeight
        )
    }

    private func day(at point: NSPoint) -> Date? {
        let days = visibleDays()
        return days.indices.first { cellRect(index: $0).contains(point) }.map { days[$0] }
    }

    override func draw(_ dirtyRect: NSRect) {
        let symbols = calendar.veryShortWeekdaySymbols
        let weekdayAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        for column in 0..<7 {
            let symbol = symbols[(firstWeekday - 1 + column) % 7] as NSString
            let size = symbol.size(withAttributes: weekdayAttributes)
            let x = inset + CGFloat(column) * columnWidth + (columnWidth - size.width) / 2
            symbol.draw(at: NSPoint(x: x, y: headerHeight + (weekdayHeight - size.height) / 2), withAttributes: weekdayAttributes)
        }

        for (index, day) in visibleDays().enumerated() {
            let rect = cellRect(index: index)
            let isCurrentMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
            let isToday = calendar.isDateInToday(day)
            let isSelected = selectedDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false

            let highlight = NSRect(x: rect.midX - 12, y: rect.minY + 1, width: 24, height: rect.height - 2)
            if isSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: highlight, xRadius: 5, yRadius: 5).fill()
            } else if hoveredDay == day {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: highlight, xRadius: 5, yRadius: 5).fill()
            }

            let color: NSColor = isToday ? .controlAccentColor : isCurrentMonth ? .maText : .tertiaryLabelColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: isToday ? .bold : .regular),
                .foregroundColor: color,
            ]
            let number = "\(calendar.component(.day, from: day))" as NSString
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + 3), withAttributes: attributes)

            guard daysWithNote.contains(day) else { continue }
            let dotSize: CGFloat = 4
            (isCurrentMonth ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - dotSize / 2, y: rect.maxY - 8, width: dotSize, height: dotSize)).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let day = day(at: convert(event.locationInWindow, from: nil))
        if day != hoveredDay { hoveredDay = day; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredDay = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let day = day(at: convert(event.locationInWindow, from: nil)) else { return }
        if !calendar.isDate(day, equalTo: month, toGranularity: .month) { show(month: day) }
        onSelectDate?(day)
    }
}
