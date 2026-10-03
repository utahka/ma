import AppKit

/// Notion のトグルのように開閉できるブロック。書式は折りたためるコールアウト `> [!toggle]- タイトル` で、
/// Obsidian でも折りたたみとして表示される（`-` はたたんだ状態、`+` は開いた状態で開く）。
/// 中身は見出し行に続く `>` 付きの行で、段落・リスト・表・コールアウト・別のトグルなどを入れられる
struct ToggleBlock: Equatable {
    /// 見出し行の先頭（UTF-16）
    let header: Int
    /// 見出し行のタイトルの先頭（`[!toggle]-` と後ろの空白の後ろ）
    let titleStart: Int
    /// 見出し行の末尾（改行の手前）
    let headerEnd: Int
    /// 見出し行の `[!toggle]` の手前までの `>` の並び。中身の行の行頭に付ける
    let prefix: String
    /// 見出し行の `>` の数。入れ子のトグルは 2 以上
    let depth: Int
    /// 中身の行。見出し行の次の行の先頭から、最後の行の末尾（改行の手前）まで。中身がなければ nil
    let content: NSRange?
    /// ファイルで `-`（たたんだ状態）になっているか
    let foldedInFile: Bool

    /// 中身の各行の範囲（改行の手前まで）
    func contentLines(in string: NSString) -> [NSRange] {
        guard let content else { return [] }
        var lines: [NSRange] = []
        var position = content.location
        while true {
            let line = string.lineRange(for: NSRange(location: position, length: 0))
            var end = NSMaxRange(line)
            while end > line.location, [0x0A, 0x0D].contains(string.character(at: end - 1)) { end -= 1 }
            lines.append(NSRange(location: line.location, length: end - line.location))
            // 最後の行は、次の行の先頭が中身の末尾を越える（ファイル末尾で改行がなければ末尾に等しい）
            guard NSMaxRange(line) < NSMaxRange(content) else { return lines }
            position = NSMaxRange(line)
        }
    }

    /// 開閉の印で、ファイルの `-`/`+` と逆の状態にしているとき `flipped`。たたんで見せるかどうかを返す
    func isCollapsed(flipped: Bool) -> Bool { foldedInFile != flipped }

    /// 見出し行。1 は `>` の並び、2 は `+`/`-`
    static let headerPattern = try! NSRegularExpression(pattern: #"^((?:>[ \t]?)+)\[!toggle\]([+-])?"#, options: [.caseInsensitive])
    /// 行頭の `>` の並び
    private static let quotePrefix = try! NSRegularExpression(pattern: #"^(?:>[ \t]?)+"#)

    /// 行頭の `>` の数
    static func depth(of line: String) -> Int {
        let string = line as NSString
        guard let match = quotePrefix.firstMatch(in: line, range: NSRange(location: 0, length: string.length)) else { return 0 }
        return string.substring(with: match.range).filter { $0 == ">" }.count
    }

    /// 行頭の `>` の並びの文字数（UTF-16）
    static func prefixLength(of line: String) -> Int {
        quotePrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))?.range.length ?? 0
    }

    /// `>` を `depth` 個並べた行頭（`> ` `> > ` など）
    static func prefix(depth: Int) -> String {
        String(repeating: "> ", count: depth)
    }

    /// 本文中のトグルを行の順に返す。装飾（MarkdownStyler）と同じく、`>` の続く行のまとまりの先頭がトグルの見出し行のときだけトグルとし、
    /// その中身の中でさらに1段深いまとまりを探す。引用やほかのコールアウトの中は探さない
    static func find(in text: String) -> [ToggleBlock] {
        let string = text as NSString
        var lines: [(range: NSRange, text: String, depth: Int)] = []
        var position = 0
        while position < string.length {
            let line = string.lineRange(for: NSRange(location: position, length: 0))
            var end = NSMaxRange(line)
            while end > line.location, [0x0A, 0x0D].contains(string.character(at: end - 1)) { end -= 1 }
            let range = NSRange(location: line.location, length: end - line.location)
            let lineText = string.substring(with: range)
            lines.append((range, lineText, depth(of: lineText)))
            position = NSMaxRange(line)
        }
        var result: [ToggleBlock] = []
        func scan(_ indices: Range<Int>, depth: Int) {
            var index = indices.lowerBound
            while index < indices.upperBound {
                guard lines[index].depth >= depth else { index += 1; continue }
                var end = index + 1
                while end < indices.upperBound, lines[end].depth >= depth { end += 1 }
                let first = lines[index]
                if first.depth == depth,
                   let match = headerPattern.firstMatch(in: first.text, range: NSRange(location: 0, length: (first.text as NSString).length)) {
                    let sign = match.range(at: 2)
                    let folded = sign.location != NSNotFound && (first.text as NSString).substring(with: sign) == "-"
                    let content = end > index + 1
                        ? NSRange(location: lines[index + 1].range.location,
                                  length: NSMaxRange(lines[end - 1].range) - lines[index + 1].range.location)
                        : nil
                    var title = NSMaxRange(match.range)
                    let characters = first.text as NSString
                    while title < characters.length, [0x20, 0x09].contains(characters.character(at: title)) { title += 1 }
                    result.append(ToggleBlock(
                        header: first.range.location, titleStart: first.range.location + title, headerEnd: NSMaxRange(first.range),
                        prefix: (first.text as NSString).substring(with: match.range(at: 1)), depth: depth,
                        content: content, foldedInFile: folded
                    ))
                    scan((index + 1)..<end, depth: depth + 1)
                }
                index = end
            }
        }
        scan(0..<lines.count, depth: 1)
        return result
    }

    // MARK: - 描画

    /// 見出し行のタイトルと中身の字下げ
    static let indent: CGFloat = 24
    /// ▸/▾ の中心の、本文の左端からの距離
    static let triangleCenter: CGFloat = 9

    static func drawTriangle(collapsed: Bool, center: CGPoint) {
        let name = collapsed ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill"
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(.init(paletteColors: [.secondaryLabelColor]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return }
        let size = image.size
        image.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
