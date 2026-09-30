import AppKit

/// 子の行を持つリスト項目。行頭の ▸/▾ で子の行を折りたためる（Obsidian の「インデントの折りたたみ」と同じ考え方）。
/// 折りたたみの状態はファイルに書かず、Ma がノートごとに覚える
struct ListToggle: Equatable {
    /// 項目の最初の行の先頭（UTF-16）
    let start: Int
    /// 行頭の空白の文字数。▸/▾ は記号の手前に置く
    let indentLength: Int
    /// 折りたたむ行。2行目の先頭から最後の行の末尾（改行の手前）まで
    let hidden: NSRange
    /// 覚えておくための名前。記号・チェックボックス・行頭の空白を除いた最初の行の文字で、
    /// 階層の変更・番号の振り直し・チェックの切り替えでは変わらない
    let key: String

    /// 項目の最初の行の末尾（改行の手前）
    var headerEnd: Int { hidden.location - 1 }

    private static let marker = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d+[.)])(?:[ \t]+\[[ xX-]\])?(?=[ \t]|$)"#)

    /// 本文中のトグルを行の順に返す。引用・コールアウトの中のリストは対象にしない
    static func find(in text: String) -> [ListToggle] {
        let mover = BlockMover(text)
        var starts: [Int] = []
        var offset = 0
        for line in mover.lines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }
        return mover.blocks.compactMap { block in
            guard block.kind == .listItem, block.lines.count > 1 else { return nil }
            let first = block.lines.lowerBound, last = block.lines.upperBound
            let hiddenStart = starts[first + 1]
            let hiddenEnd = starts[last] + (mover.lines[last] as NSString).length
            let line = mover.lines[first] as NSString
            let prefix = marker.firstMatch(in: mover.lines[first], range: NSRange(location: 0, length: line.length))?.range.length ?? 0
            let key = line.substring(from: prefix).trimmingCharacters(in: .whitespaces)
            return ListToggle(start: starts[first], indentLength: (block.indent as NSString).length,
                              hidden: NSRange(location: hiddenStart, length: hiddenEnd - hiddenStart), key: key)
        }
    }

    // MARK: - 保存

    private static let defaultsKey = "listFolds"

    /// 保存する形。同じ文字の項目が複数あるときに区別するため、同じ名前の中での順番を前に付ける（`1\t名前`）
    static func storedKeys(of folded: Set<Int>, in toggles: [ListToggle]) -> [String] {
        var counts: [String: Int] = [:]
        var result: [String] = []
        for toggle in toggles {
            let occurrence = counts[toggle.key, default: 0]
            counts[toggle.key] = occurrence + 1
            if folded.contains(toggle.start) { result.append("\(occurrence)\t\(toggle.key)") }
        }
        return result
    }

    /// 保存した名前を今の本文の項目の位置に戻す。見つからない名前は捨てる
    static func restore(_ keys: [String], in toggles: [ListToggle]) -> Set<Int> {
        let wanted = Set(keys)
        var counts: [String: Int] = [:]
        var result = Set<Int>()
        for toggle in toggles {
            let occurrence = counts[toggle.key, default: 0]
            counts[toggle.key] = occurrence + 1
            if wanted.contains("\(occurrence)\t\(toggle.key)") { result.insert(toggle.start) }
        }
        return result
    }

    static func load(for url: URL) -> [String] {
        let stored = AppDefaults.shared.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
        return stored[url.path] ?? []
    }

    static func save(_ keys: [String], for url: URL) {
        var stored = AppDefaults.shared.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
        guard stored[url.path] ?? [] != keys else { return }
        stored[url.path] = keys.isEmpty ? nil : keys
        AppDefaults.shared.set(stored, forKey: defaultsKey)
    }

    // MARK: - 描画

    /// ▸/▾ の四角の一辺
    static let buttonSize: CGFloat = 16

    static func image(collapsed: Bool) -> NSImage? {
        let name = collapsed ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill"
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(.init(paletteColors: [.secondaryLabelColor]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    /// `rect` の中央に ▸/▾ を描く
    static func drawTriangle(collapsed: Bool, in rect: CGRect) {
        guard let image = image(collapsed: collapsed) else { return }
        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// たたんだトグルの最初の行に付ける。フラグメントが記号の左に ▸ を描く
final class ListFoldDecoration: NSObject, @unchecked Sendable {
    let indentLength: Int

    init(indentLength: Int) {
        self.indentLength = indentLength
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? ListFoldDecoration)?.indentLength == indentLength
    }

    override var hash: Int { indentLength }
}

/// マウスのあるトグルの記号の左に出す ▾ のボタン。たたんだ項目の ▸ はフラグメントが描くので、ここでは背景だけを描く
final class ListToggleButton: NSView {
    var onClick: (() -> Void)?
    var collapsed = false { didSet { needsDisplay = true } }
    /// 押したときに開閉する項目の先頭
    var start: Int?
    private var isHovered = false

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        if !collapsed { ListToggle.drawTriangle(collapsed: false, in: bounds) }
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    // 本文に渡すとカーソルが動くので、押した時点で開閉して止める
    override func mouseDown(with event: NSEvent) { onClick?() }
}
