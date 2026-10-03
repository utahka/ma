import Foundation

/// リスト項目の行と、その続きの行（Shift+Enter で項目の中で改行した行）の判定。
/// 続きの行は、リスト項目の行ではなく、項目の行より深く字下げした行。Shift+Enter では項目の本文の開始位置まで空白で字下げする
/// （`- [ ] 本文` なら6文字、`- 本文` なら2文字、`1. 本文` なら3文字）。Obsidian でも同じ項目の続きとして読める。
/// 続きの行は子の項目ではない。子の項目は、項目の行より深く字下げしたリスト項目の行だけ。
/// 画面に依存しないので swiftc で単体確認できる
enum ListLine {
    /// 項目の行の行頭。引用の `>` の中の項目は扱わない
    struct Marker: Equatable {
        /// 行頭の空白（項目の階層）
        let indent: String
        /// 記号（`-` `*` `+` `1.` `1)`）
        let bullet: String
        /// 記号の後ろの空白
        let spacing: String
        /// チェックボックス（`[ ]` と後ろの空白）。なければ nil
        let checkbox: String?

        /// 行頭から本文の開始位置までの文字数（UTF-16）
        var length: Int { ((indent + bullet + spacing + (checkbox ?? "")) as NSString).length }
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*+]|\d{1,9}[.)])( +|\t|$)(\[[ xX]\](?: +|$))?"#
    )

    /// リスト項目の行なら行頭の記号を返す
    static func marker(of line: String) -> Marker? {
        let string = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: string.length)) else { return nil }
        func text(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : string.substring(with: range)
        }
        return Marker(indent: text(1) ?? "", bullet: text(2) ?? "", spacing: text(3) ?? "", checkbox: text(4))
    }

    static func isItem(_ line: String) -> Bool { marker(of: line) != nil }

    /// その項目の続きの行の行頭に置く空白。項目のインデントのあとに、記号から本文の開始位置までの文字数ぶんの空白を足す
    static func continuationIndent(for marker: Marker) -> String {
        let markerLength = marker.length - (marker.indent as NSString).length
        return marker.indent + String(repeating: " ", count: max(markerLength, 1))
    }

    /// `line` が項目 `item`（リスト項目の行）の続きの行として読めるか。
    /// リスト項目の行でなく、空行でもなく、項目の行より深く字下げしてある行
    static func isContinuation(_ line: String, of item: String) -> Bool {
        guard let marker = marker(of: item), !isItem(line), !isBlank(line) else { return false }
        return columns(leadingWhitespace(line)) > columns(marker.indent)
    }

    /// `lines[index]` が続きの行なら、その項目の行の番号。
    /// 上へたどり、空行や字下げのない行に当たる前に見つかった項目のうち、この行より浅い最初の項目を持ち主とする
    /// （子の項目の下にあっても、子より浅い行は親の続き）。`allowsBlank` なら空白だけの行も続きの行として扱う（入力中の行）
    static func owner(ofLine index: Int, in lines: [String], allowsBlank: Bool = false) -> Int? {
        owner(of: lines[index], allowsBlank: allowsBlank, above: (0..<index).reversed().lazy.map { ($0, lines[$0]) })
    }

    /// `owner(ofLine:in:)` と同じ判定を、上の行を近い順に返す列で行う
    static func owner<S: Sequence>(of line: String, allowsBlank: Bool = false, above: S) -> Int?
        where S.Element == (Int, String) {
        guard !isItem(line), allowsBlank || !isBlank(line) else { return nil }
        let depth = columns(leadingWhitespace(line))
        guard depth > 0 else { return nil }
        for (index, previous) in above {
            if isBlank(previous) { return nil }
            if let marker = marker(of: previous) {
                if depth > columns(marker.indent) { return index }
                continue
            }
            // 字下げのない行（別の段落やコードの囲みなど）より上へはたどらない
            if leadingWhitespace(previous).isEmpty { return nil }
        }
        return nil
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// 字下げの深さ。タブは空白2つと数える（ライブプレビューの1段の幅と同じ）
    static func columns(_ whitespace: String) -> Int {
        whitespace.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
    }
}
