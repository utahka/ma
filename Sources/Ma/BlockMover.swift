import Foundation

/// ドラッグで動かせるまとまり。段落・見出し・リスト項目（子の項目を含む）・引用とコールアウト・表・コードブロック
struct MarkdownBlock: Equatable {
    enum Kind { case paragraph, heading, listItem, quote, table, code, rule }

    let kind: Kind
    /// 最初と最後の行番号（0 始まり、両端を含む）
    let lines: ClosedRange<Int>
    /// 行頭の空白（リスト項目の階層を表す）
    let indent: String
}

/// 行単位で Markdown をブロックに分け、ブロックを別の位置へ動かす
struct BlockMover {
    let lines: [String]
    /// 行の順に並ぶ。リストの親は子より前にあるので、条件に合う最後の要素がいちばん内側になる
    let blocks: [MarkdownBlock]

    init(_ text: String) {
        lines = text.components(separatedBy: "\n")
        blocks = Self.parse(lines)
    }

    /// 落とし先。`line` の行の手前に入れ、リスト項目なら行頭の空白を `indent` にそろえる
    struct Drop: Equatable {
        let line: Int
        let indent: String?
    }

    /// その行を先頭にもつブロックのうち、いちばん内側のもの
    func block(startingAt line: Int) -> MarkdownBlock? {
        blocks.last { $0.lines.lowerBound == line }
    }

    /// その行を含むブロックのうち、いちばん内側のもの
    func block(containing line: Int) -> MarkdownBlock? {
        blocks.last { $0.lines.contains(line) }
    }

    /// リスト項目の子の項目（孫も含む）。項目の範囲の中で、先頭の行より後ろから始まるリスト項目。
    /// 続きの行（Shift+Enter で項目の中で改行した、リスト項目でない行。`ListLine`）は子に含めない
    func childItems(of item: MarkdownBlock) -> [MarkdownBlock] {
        guard item.kind == .listItem else { return [] }
        return blocks.filter { $0.kind == .listItem && $0.lines.lowerBound > item.lines.lowerBound
            && item.lines.contains($0.lines.lowerBound) }
    }

    /// リスト項目の続きの行の行番号。項目の範囲のうち、先頭の行と子の項目の行を除いた行
    func continuationLines(of item: MarkdownBlock) -> [Int] {
        guard item.kind == .listItem else { return [] }
        let children = childItems(of: item)
        return item.lines.dropFirst().filter { line in !children.contains { $0.lines.contains(line) } }
    }

    /// 落とし先になりうる行。各ブロックの先頭と文書の末尾
    var dropLines: [Int] {
        var result = Set(blocks.map(\.lines.lowerBound))
        if let last = lastContentLine { result.insert(last + 1) }
        return result.sorted()
    }

    private var lastContentLine: Int? {
        lines.lastIndex { !Self.isBlank($0) }
    }

    /// `line` に落とすときに選べるリストの階層（浅い順）。
    /// 次のブロックがリスト項目ならその階層、直前で終わるリスト項目があればその階層を候補にする。
    /// `isHidden` はたたんで隠した行か。隠した項目の階層と、たたんだ項目の子になる階層は選ばない
    func indentChoices(for block: MarkdownBlock, at line: Int, isHidden: (Int) -> Bool = { _ in false }) -> [String] {
        guard block.kind == .listItem else { return [] }
        var choices: [String] = []
        if let next = self.block(startingAt: line), next.kind == .listItem { choices.append(next.indent) }
        let previousLine = (0..<line).last { !Self.isBlank(lines[$0]) }
        for item in blocks where item.kind == .listItem && item.lines.upperBound == previousLine
            && !item.lines.overlaps(block.lines) && !isHidden(item.lines.lowerBound) {
            choices.append(item.indent)
            // 直前の項目の子になる
            if !isHidden(item.lines.lowerBound + 1) { choices.append(item.indent + Self.indentUnit(in: lines)) }
        }
        if choices.isEmpty { choices.append("") }
        return Array(Set(choices)).sorted { $0.count < $1.count }
    }

    /// 動かしたあとの本文と、動かしたブロックの先頭の文字位置（UTF-16）。動かないときは nil
    func move(_ block: MarkdownBlock, to drop: Drop) -> (text: String, location: Int)? {
        let range = block.lines
        let reindent = drop.indent.map { $0 != block.indent } ?? false
        guard !range.contains(drop.line) || (drop.line == range.lowerBound && reindent),
              !(drop.line == range.upperBound + 1 && !reindent) else { return nil }

        var moved = Array(lines[range])
        if let indent = drop.indent, block.kind == .listItem {
            moved = moved.map { $0.hasPrefix(block.indent) ? indent + $0.dropFirst(block.indent.count) : $0 }
        }
        let movedBlock = MarkdownBlock(kind: block.kind, lines: range, indent: drop.indent ?? block.indent)

        // 1. 元の位置から外し、前後の空行を詰める
        var rest = lines
        var target = drop.line
        let (before, after) = blankRuns(around: range)
        let previous = neighbor(before: range.lowerBound - before.count)
        let next = neighbor(startingAt: range.upperBound + 1 + after.count)
        let keepBlank = (!before.isEmpty && !after.isEmpty) || Self.needsBlank(previous, next)
        let removeStart = range.lowerBound - before.count
        let removeEnd = range.upperBound + after.count
        let removed = (removeStart...removeEnd).count
        let separator = previous == nil || next == nil ? [] : keepBlank ? [""] : []
        rest.replaceSubrange(removeStart...removeEnd, with: separator)
        if target > removeEnd { target -= removed - separator.count }
        else if target > removeStart { target = removeStart }

        // 2. 落とし先の前後の空行を作り直して差し込む
        var gapStart = target
        while gapStart > 0, Self.isBlank(rest[gapStart - 1]) { gapStart -= 1 }
        var gapEnd = target
        while gapEnd < rest.count, Self.isBlank(rest[gapEnd]) { gapEnd += 1 }
        // 文書の末尾に落とすときは、末尾の空行（改行で終わるファイルの最後の空文字列）を残す
        let atEnd = gapEnd == rest.count
        if atEnd { gapEnd = gapStart }
        let hadBlank = gapEnd > gapStart
        let restMover = BlockMover(lines: rest)
        let above = gapStart > 0 ? restMover.block(endingAt: gapStart - 1) : nil
        let below = atEnd ? nil : restMover.outermostBlock(startingAt: gapEnd)
        var inserted: [String] = []
        if above != nil, hadBlank || Self.needsBlank(above, movedBlock) { inserted.append("") }
        let firstLine = gapStart + inserted.count
        inserted += moved
        if below != nil, Self.needsBlank(movedBlock, below) { inserted.append("") }
        rest.replaceSubrange(gapStart..<gapEnd, with: inserted)

        let text = rest.joined(separator: "\n")
        guard text != lines.joined(separator: "\n") else { return nil }
        let location = rest[..<firstLine].reduce(0) { $0 + ($1 as NSString).length + 1 }
        return (text, location)
    }

    /// Tab・Shift+Tab でリスト項目を1段ずらした結果。`selection` の行から始まる項目（なければカーソル行を含む項目）と、
    /// その子の行が対象。`lines` の範囲を `text` に置き換え、`shifts` は各行の行頭で増えた（負なら減った）文字数（UTF-16）。
    /// リスト項目の行でなければ nil。動かせない（Shift+Tab で一番浅い）ときは何も変えない結果を返す
    func shiftingListItems(in selection: ClosedRange<Int>, outdent: Bool)
        -> (lines: ClosedRange<Int>, text: [String], shifts: [Int])? {
        var items = blocks.filter { $0.kind == .listItem && selection.contains($0.lines.lowerBound) }
        if items.isEmpty, let item = block(containing: selection.lowerBound), item.kind == .listItem { items = [item] }
        guard !items.isEmpty else { return nil }
        // 一番浅い項目は Shift+Tab で動かさず、子の項目も今の階層のまま残す
        if outdent { items = items.filter { !$0.indent.isEmpty } }
        guard let first = items.map(\.lines.lowerBound).min(),
              let last = items.map(\.lines.upperBound).max()
        else { return (selection.lowerBound...selection.lowerBound, [lines[selection.lowerBound]], [0]) }
        let targets = Set(items.flatMap { Array($0.lines) })
        let unit = Self.indentUnit(in: lines)
        var text: [String] = []
        var shifts: [Int] = []
        for index in first...last {
            let line = lines[index]
            guard targets.contains(index), !Self.isBlank(line) else {
                text.append(line); shifts.append(0); continue
            }
            if !outdent {
                text.append(unit + line); shifts.append((unit as NSString).length); continue
            }
            // タブは1文字、空白は1段ぶん（文書の単位がタブなら空白2つ）まで外す
            let removed = line.hasPrefix("\t") ? 1
                : min(line.prefix { $0 == " " }.count, unit == "\t" ? 2 : unit.count)
            text.append(String(line.dropFirst(removed))); shifts.append(-removed)
        }
        return (first...last, text, shifts)
    }

    // MARK: - 内部

    private init(lines: [String]) {
        self.lines = lines
        blocks = Self.parse(lines)
    }

    private func block(endingAt line: Int) -> MarkdownBlock? {
        blocks.last { $0.lines.upperBound == line }
    }

    private func outermostBlock(startingAt line: Int) -> MarkdownBlock? {
        blocks.first { $0.lines.lowerBound == line }
    }

    private func neighbor(before line: Int) -> MarkdownBlock? {
        line > 0 ? block(endingAt: line - 1) : nil
    }

    private func neighbor(startingAt line: Int) -> MarkdownBlock? {
        line < lines.count ? outermostBlock(startingAt: line) : nil
    }

    private func blankRuns(around range: ClosedRange<Int>) -> (before: [Int], after: [Int]) {
        var before: [Int] = []
        var line = range.lowerBound - 1
        while line >= 0, Self.isBlank(lines[line]) { before.append(line); line -= 1 }
        var after: [Int] = []
        line = range.upperBound + 1
        while line < lines.count, Self.isBlank(lines[line]) { after.append(line); line += 1 }
        // 末尾の空文字列（ファイル末尾の改行）は残す
        if line == lines.count, !after.isEmpty { after.removeLast() }
        return (before, after)
    }

    /// 並べたときに空行で区切らないと、ひとつのブロックとして読まれてしまうか
    private static func needsBlank(_ a: MarkdownBlock?, _ b: MarkdownBlock?) -> Bool {
        guard let a, let b else { return false }
        if a.kind == .listItem && b.kind == .listItem { return false }
        // 見出しの直後は空行なしで続けて書ける（「## TODO」の次の行にコールアウトを置くなど）
        if a.kind == .heading || a.kind == .rule { return false }
        return true
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// 文書で使われている1段ぶんのインデント。タブがあればタブ
    static func indentUnit(in lines: [String]) -> String {
        let indents = lines.filter { isListItem($0) }.map(leadingWhitespace).filter { !$0.isEmpty }
        if indents.isEmpty || indents.contains(where: { $0.hasPrefix("\t") }) { return "\t" }
        return String(repeating: " ", count: indents.map(\.count).min() ?? 4)
    }

    private static func isListItem(_ line: String) -> Bool {
        line.contains(/^[ \t]*([-*+]|\d+[.)])([ \t]|$)/)
    }

    private static func parse(_ lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var i = 0
        // フロントマターは動かさない
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { i = end + 1 }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if isBlank(line) { i += 1; continue }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                var end = i + 1
                while end < lines.count, !lines[end].drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(marker) { end += 1 }
                end = min(end, lines.count - 1)
                blocks.append(MarkdownBlock(kind: .code, lines: i...end, indent: ""))
                i = end + 1
            } else if isListItem(line) {
                parseList(lines, from: &i, into: &blocks)
            } else if trimmed.hasPrefix(">") || trimmed.hasPrefix("|") {
                let marker = trimmed.first!
                var end = i
                while end + 1 < lines.count, lines[end + 1].drop(while: { $0 == " " || $0 == "\t" }).first == marker { end += 1 }
                blocks.append(MarkdownBlock(kind: marker == ">" ? .quote : .table, lines: i...end, indent: ""))
                i = end + 1
            } else if line.contains(/^#{1,6}([ \t]|$)/) {
                blocks.append(MarkdownBlock(kind: .heading, lines: i...i, indent: ""))
                i += 1
            } else if line.contains(/^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$/) {
                blocks.append(MarkdownBlock(kind: .rule, lines: i...i, indent: ""))
                i += 1
            } else {
                var end = i
                while end + 1 < lines.count, !isBlank(lines[end + 1]), !startsBlock(lines[end + 1]) { end += 1 }
                blocks.append(MarkdownBlock(kind: .paragraph, lines: i...end, indent: ""))
                i = end + 1
            }
        }
        return blocks
    }

    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        return isListItem(line) || trimmed.hasPrefix(">") || trimmed.hasPrefix("|") || trimmed.hasPrefix("```")
            || trimmed.hasPrefix("~~~") || line.contains(/^#{1,6}([ \t]|$)/)
    }

    /// 続くリスト項目をまとめて読む。項目は、それより深い行（子の項目や続きの行）までを含む
    private static func parseList(_ lines: [String], from i: inout Int, into blocks: inout [MarkdownBlock]) {
        var end = i
        while end + 1 < lines.count, !isBlank(lines[end + 1]),
              isListItem(lines[end + 1]) || !startsBlock(lines[end + 1]) { end += 1 }
        for line in i...end where isListItem(lines[line]) {
            let indent = leadingWhitespace(lines[line])
            let depth = columns(indent)
            var last = line
            while last + 1 <= end, columns(leadingWhitespace(lines[last + 1])) > depth || !isListItem(lines[last + 1]) {
                last += 1
            }
            blocks.append(MarkdownBlock(kind: .listItem, lines: line...last, indent: indent))
        }
        i = end + 1
    }

    private static func columns(_ whitespace: String) -> Int {
        whitespace.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
    }
}
