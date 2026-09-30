import AppKit

/// `/` で呼び出す入力補助の1項目
@MainActor
struct SlashCommand {
    enum Action {
        /// 行頭の記号（見出し・リストなど）を差し替える。空文字なら記号を外して本文に戻す
        case linePrefix(String)
        /// `/…` の位置に文字を入れる。`block` なら前後の文字と別の行にする。`selection` の位置が文字数を超えるときは末尾
        case insert(text: () -> String, selection: NSRange, block: Bool, blankLineAbove: Bool = false)
    }

    let title: String
    /// 右側に薄く出す、入力される Markdown の目安
    let hint: String
    let symbol: String
    /// 絞り込みに使う英語やローマ字の別名
    let keywords: [String]
    let action: Action

    static let all: [SlashCommand] = [
        SlashCommand(title: "本文", hint: "", symbol: "text.alignleft", keywords: ["text", "paragraph", "honbun"], action: .linePrefix("")),
        SlashCommand(title: "見出し1", hint: "#", symbol: "1.square", keywords: ["h1", "heading1", "midashi1"], action: .linePrefix("# ")),
        SlashCommand(title: "見出し2", hint: "##", symbol: "2.square", keywords: ["h2", "heading2", "midashi2"], action: .linePrefix("## ")),
        SlashCommand(title: "見出し3", hint: "###", symbol: "3.square", keywords: ["h3", "heading3", "midashi3"], action: .linePrefix("### ")),
        SlashCommand(title: "箇条書き", hint: "-", symbol: "list.bullet", keywords: ["bullet", "list", "ul", "kajougaki"], action: .linePrefix("- ")),
        SlashCommand(title: "番号付きリスト", hint: "1.", symbol: "list.number", keywords: ["numbered", "ol", "list", "bangou"], action: .linePrefix("1. ")),
        SlashCommand(title: "チェックリスト", hint: "- [ ]", symbol: "checklist", keywords: ["todo", "task", "checkbox", "checklist"], action: .linePrefix("- [ ] ")),
        SlashCommand(title: "引用", hint: ">", symbol: "text.quote", keywords: ["quote", "blockquote", "inyou"], action: .linePrefix("> ")),
        SlashCommand(title: "コールアウト", hint: "> [!note]", symbol: "exclamationmark.bubble", keywords: ["callout", "note", "tip"],
                     action: .insert(text: { "> [!note]\n> " }, selection: NSRange(location: 12, length: 0), block: true)),
        SlashCommand(title: "コードブロック", hint: "```", symbol: "chevron.left.forwardslash.chevron.right", keywords: ["code", "codeblock"],
                     action: .insert(text: { "```\n\n```" }, selection: NSRange(location: 4, length: 0), block: true)),
        SlashCommand(title: "表", hint: "| |", symbol: "tablecells", keywords: ["table", "hyou"],
                     action: .insert(text: { "| 列1 | 列2 |\n| --- | --- |\n|  |  |" }, selection: NSRange(location: 2, length: 2), block: true)),
        SlashCommand(title: "区切り線", hint: "---", symbol: "minus", keywords: ["divider", "hr", "line", "kugiri"],
                     action: .insert(text: { "---\n" }, selection: NSRange(location: 4, length: 0), block: true, blankLineAbove: true)),
        SlashCommand(title: "ノートへのリンク", hint: "[[ ]]", symbol: "link", keywords: ["link", "wikilink", "rinku"],
                     action: .insert(text: { "[[]]" }, selection: NSRange(location: 2, length: 0), block: false)),
        SlashCommand(title: "今日の日付", hint: "", symbol: "calendar", keywords: ["date", "today", "hiduke", "kyou"],
                     action: .insert(text: { format(Date(), "yyyy-MM-dd") }, selection: NSRange(location: .max, length: 0), block: false)),
        SlashCommand(title: "現在時刻", hint: "", symbol: "clock", keywords: ["time", "now", "jikoku"],
                     action: .insert(text: { format(Date(), "HH:mm") }, selection: NSRange(location: .max, length: 0), block: false)),
    ]

    private static func format(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// `/` の後ろに打った文字で絞り込む。名前か別名の先頭に一致するものを先に並べる
    static func matching(_ query: String) -> [SlashCommand] {
        let query = query.lowercased()
        guard !query.isEmpty else { return all }
        let keys = { (command: SlashCommand) in [command.title.lowercased()] + command.keywords }
        let prefixed = all.filter { keys($0).contains { $0.hasPrefix(query) } }
        let contained = all.filter { command in
            !keys(command).contains { $0.hasPrefix(query) } && keys(command).contains { $0.contains(query) }
        }
        return prefixed + contained
    }

    /// `slash`（`/` の位置）から `caret` までを置き換える編集。選択範囲は置き換え後の文書での位置
    func edit(in text: NSString, slash: Int, caret: Int) -> (range: NSRange, replacement: String, selection: NSRange) {
        let line = text.lineRange(for: NSRange(location: slash, length: 0))
        var lineEnd = NSMaxRange(line)
        while lineEnd > line.location, [0x0A, 0x0D].contains(text.character(at: lineEnd - 1)) { lineEnd -= 1 }
        let before = text.substring(with: NSRange(location: line.location, length: slash - line.location))
        let after = text.substring(with: NSRange(location: caret, length: lineEnd - caret))

        switch action {
        case .linePrefix(let marker):
            let content = before + after
            let nsContent = content as NSString
            let match = Self.linePrefixPattern.firstMatch(in: content, range: NSRange(location: 0, length: nsContent.length))
            let indent = match.map { nsContent.substring(with: $0.range(at: 1)) } ?? ""
            let prefixLength = match?.range.length ?? 0
            let rest = nsContent.substring(from: prefixLength)
            let caretInRest = max(0, (before as NSString).length - prefixLength)
            let caret = line.location + (indent as NSString).length + (marker as NSString).length + caretInRest
            return (NSRange(location: line.location, length: lineEnd - line.location), indent + marker + rest,
                    NSRange(location: caret, length: 0))
        case .insert(let makeText, let selection, let block, let blankLineAbove):
            let inserted = makeText()
            var leading = ""
            var trailing = ""
            if block {
                if !before.trimmingCharacters(in: .whitespaces).isEmpty {
                    leading = "\n"
                } else if blankLineAbove, line.location > 0 {
                    // 文字のある行の直下の `---` は見出し（setext）になるので、空行を挟む
                    let previous = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
                    if !text.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { leading = "\n" }
                }
                if !after.isEmpty, !inserted.hasSuffix("\n") { trailing = "\n" }
            }
            let offset = slash + (leading as NSString).length
            return (NSRange(location: slash, length: caret - slash), leading + inserted + trailing,
                    NSRange(location: offset + min(selection.location, (inserted as NSString).length), length: selection.length))
        }
    }

    /// 行頭のインデントと、見出し・リスト・チェックボックス・引用の記号
    private static let linePrefixPattern = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:#{1,6} |[-*+] \[.\] |[-*+] |\d+[.)] |> )?"#
    )
}

/// 候補の一覧。エディタのウインドウの子ウインドウとしてカーソルの下に出す。
/// キー入力はエディタが受けたまま、↑↓・Enter・Esc を `EditorViewController` から渡す
@MainActor
final class SlashMenu {
    var onChoose: ((SlashCommand) -> Void)?
    private let panel: NSPanel
    private let list = SlashMenuView()
    private let scrollView = NSScrollView()
    private static let width: CGFloat = 260
    private static let maxVisibleRows = 9

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = list
        scrollView.autoresizingMask = [.width, .height]
        background.addSubview(scrollView)
        panel.contentView = background
        list.onChoose = { [weak self] index in
            guard let self, list.commands.indices.contains(index) else { return }
            onChoose?(list.commands[index])
        }
    }

    /// `anchor` は `/` の文字の画面上の矩形
    func show(_ commands: [SlashCommand], below anchor: NSRect, in window: NSWindow) {
        if list.commands.map(\.title) != commands.map(\.title) {
            list.commands = commands
            list.selected = 0
        }
        let padding = SlashMenuView.padding
        let height = CGFloat(min(commands.count, Self.maxVisibleRows)) * SlashMenuView.rowHeight + padding * 2
        list.frame = NSRect(x: 0, y: 0, width: Self.width, height: CGFloat(commands.count) * SlashMenuView.rowHeight + padding * 2)
        var origin = NSPoint(x: anchor.minX - padding, y: anchor.minY - 4 - height)
        if let screen = window.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = anchor.maxY + 4 }
            origin.x = min(max(origin.x, screen.minX), screen.maxX - Self.width)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        scrollView.frame = panel.contentView?.bounds ?? .zero
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        list.needsDisplay = true
        list.scrollSelectionToVisible()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        guard !list.commands.isEmpty else { return }
        list.selected = (list.selected + delta + list.commands.count) % list.commands.count
        list.needsDisplay = true
        list.scrollSelectionToVisible()
    }

    var selectedCommand: SlashCommand? {
        list.commands.indices.contains(list.selected) ? list.commands[list.selected] : nil
    }
}

private final class SlashMenuView: NSView {
    static let rowHeight: CGFloat = 28
    static let padding: CGFloat = 5
    var commands: [SlashCommand] = []
    var selected = 0
    var onChoose: ((Int) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    // 子ウインドウはキーウインドウにならないので、最初のクリックから受ける
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func row(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(floor((point.y - Self.padding) / Self.rowHeight))
        return commands.indices.contains(index) ? index : nil
    }

    private func rect(ofRow index: Int) -> NSRect {
        NSRect(x: Self.padding, y: Self.padding + CGFloat(index) * Self.rowHeight, width: bounds.width - Self.padding * 2, height: Self.rowHeight)
    }

    func scrollSelectionToVisible() {
        guard commands.indices.contains(selected) else { return }
        scrollToVisible(rect(ofRow: selected).insetBy(dx: 0, dy: -Self.padding))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let index = row(at: event), index != selected else { return }
        selected = index
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = row(at: event) else { return }
        selected = index
        onChoose?(index)
    }

    override func draw(_ dirtyRect: NSRect) {
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        for (index, command) in commands.enumerated() {
            let row = rect(ofRow: index)
            guard row.intersects(dirtyRect) else { continue }
            if index == selected {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
            }
            if let image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfiguration) {
                let size = image.size
                image.draw(in: NSRect(x: row.minX + 8 + (18 - size.width) / 2, y: row.midY - size.height / 2,
                                      width: size.width, height: size.height))
            }
            let title = command.title as NSString
            let titleHeight = title.size(withAttributes: titleAttributes).height
            title.draw(at: NSPoint(x: row.minX + 34, y: row.midY - titleHeight / 2), withAttributes: titleAttributes)
            let hint = command.hint as NSString
            let hintSize = hint.size(withAttributes: hintAttributes)
            hint.draw(at: NSPoint(x: row.maxX - 8 - hintSize.width, y: row.midY - hintSize.height / 2), withAttributes: hintAttributes)
        }
    }
}
