import Foundation

/// リスト項目の中で Enter を押したときの書き換え。次の行に同じ種類の項目を作り、空の項目なら記号を消してリストを抜ける。
/// 項目の続きの行（`ListLine`）で押したときは、その項目の次の項目を作る。
/// 画面に依存しないので swiftc で単体確認できる（`ListLine.swift` と一緒にコンパイルする）
enum ListContinuation {
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        let caret: Int
    }

    /// 引用・コールアウトの `>`、インデント、記号（`-` `*` `+` `1.` `1)`）と後ろの空白、チェックボックス
    private static let pattern = try! NSRegularExpression(
        pattern: #"^((?:> ?)*)([ \t]*)(?:([-*+])|(\d{1,9})([.)]))( +)(\[[ xX]\](?: +|$))?"#
    )

    static func edit(in string: NSString, caret: Int) -> Edit? {
        let lineRange = string.lineRange(for: NSRange(location: caret, length: 0))
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location, [0x0A, 0x0D].contains(string.character(at: contentEnd - 1)) {
            contentEnd -= 1
        }
        let line = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
        guard !isInCodeBlock(string, before: lineRange.location) else { return nil }
        guard let match = pattern.firstMatch(in: string as String, range: line) else {
            return continuationEdit(in: string, line: line, caret: caret)
        }
        let markerEnd = NSMaxRange(match.range)
        // 記号の手前や途中では通常の改行にする
        guard caret >= markerEnd else { return nil }

        func text(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : string.substring(with: range)
        }
        let quote = text(1) ?? ""
        let indent = text(2) ?? ""
        let body = string.substring(with: NSRange(location: markerEnd, length: contentEnd - markerEnd))

        // 中身が空の項目: 記号とインデントを消してリストを抜ける（引用の `>` は残す）。
        // 1行目が空でも続きの行があれば空の項目とはみなさない
        if body.trimmingCharacters(in: .whitespaces).isEmpty, !hasContinuation(in: string, after: lineRange) {
            let range = NSRange(location: line.location + (quote as NSString).length,
                                length: contentEnd - line.location - (quote as NSString).length)
            return Edit(range: range, replacement: "", caret: range.location)
        }

        guard let marker = nextMarker(bullet: text(3) ?? ((text(4) ?? "") + (text(5) ?? "")),
                                      spacing: text(6) ?? " ", checkbox: text(7) != nil)
        else { return nil }
        return split(string, at: caret, bodyStart: markerEnd, contentEnd: contentEnd, insertion: "\n" + quote + indent + marker)
    }

    /// 続きの行で Enter を押したとき。持ち主の項目の次の項目を作る。空白だけの続きの行はその行ごと次の項目に置き換える
    private static func continuationEdit(in string: NSString, line: NSRange, caret: Int) -> Edit? {
        let text = string.substring(with: line)
        guard let owner = ListLine.owner(of: text, allowsBlank: true, above: linesAbove(line.location, in: string)),
              let ownerMarker = ListLine.marker(of: lineText(at: owner, in: string)),
              let marker = nextMarker(bullet: ownerMarker.bullet, spacing: ownerMarker.spacing.isEmpty ? " " : ownerMarker.spacing,
                                      checkbox: ownerMarker.checkbox != nil)
        else { return nil }
        let insertion = "\n" + ownerMarker.indent + marker
        if ListLine.isBlank(text) {
            let range = NSRange(location: line.location - 1, length: NSMaxRange(line) - line.location + 1)
            return Edit(range: range, replacement: insertion, caret: range.location + (insertion as NSString).length)
        }
        let bodyStart = line.location + (ListLine.leadingWhitespace(text) as NSString).length
        return split(string, at: max(caret, bodyStart), bodyStart: bodyStart, contentEnd: NSMaxRange(line), insertion: insertion)
    }

    /// 次の項目の記号。番号は1つ進め、チェックリストなら未完了のチェックボックスを付ける
    private static func nextMarker(bullet: String, spacing: String, checkbox: Bool) -> String? {
        var marker: String
        if ["-", "*", "+"].contains(bullet) {
            marker = bullet
        } else if let delimiter = bullet.last, ".)".contains(delimiter), let number = Int(bullet.dropLast()) {
            marker = "\(number + 1)\(delimiter)"
        } else {
            return nil
        }
        marker += spacing
        if checkbox { marker += "[ ] " }
        return marker
    }

    /// カーソルの位置に `insertion` を差し込み、カーソルの後ろの文字は新しい行へ送る。境目の空白は落とす
    static func split(_ string: NSString, at caret: Int, bodyStart: Int, contentEnd: Int, insertion: String) -> Edit {
        var cut = caret
        while cut > bodyStart, [0x20, 0x09].contains(string.character(at: cut - 1)) { cut -= 1 }
        var rest = caret
        while rest < contentEnd, [0x20, 0x09].contains(string.character(at: rest)) { rest += 1 }
        return Edit(range: NSRange(location: cut, length: rest - cut),
                    replacement: insertion,
                    caret: cut + (insertion as NSString).length)
    }

    /// 項目の行の次の行が、その項目の続きの行か
    private static func hasContinuation(in string: NSString, after lineRange: NSRange) -> Bool {
        guard NSMaxRange(lineRange) < string.length else { return false }
        let next = lineText(at: NSMaxRange(lineRange), in: string)
        return ListLine.owner(of: next, above: linesAbove(NSMaxRange(lineRange), in: string)) == lineRange.location
    }

    /// `location` の行より上の行を、近い順に（行頭の位置, 改行を除いた行）で返す
    static func linesAbove(_ location: Int, in string: NSString) -> AnySequence<(Int, String)> {
        AnySequence(sequence(state: location) { start -> (Int, String)? in
            guard start > 0 else { return nil }
            let range = string.lineRange(for: NSRange(location: start - 1, length: 0))
            start = range.location
            return (range.location, lineText(at: range.location, in: string))
        })
    }

    /// `location` を含む行の、改行を除いた文字列
    static func lineText(at location: Int, in string: NSString) -> String {
        string.substring(with: contentRange(at: location, in: string))
    }

    /// `location` を含む行の、改行を除いた範囲
    static func contentRange(at location: Int, in string: NSString) -> NSRange {
        let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
        var end = NSMaxRange(lineRange)
        while end > lineRange.location, [0x0A, 0x0D].contains(string.character(at: end - 1)) { end -= 1 }
        return NSRange(location: lineRange.location, length: end - lineRange.location)
    }

    /// 行頭の ``` / ~~~ の数を数え、コードブロックの中かを調べる
    static func isInCodeBlock(_ string: NSString, before location: Int) -> Bool {
        var inside = false
        string.substring(to: location).enumerateLines { line, _ in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inside.toggle() }
        }
        return inside
    }
}

/// リスト項目や続きの行で Shift+Enter を押したときの書き換え。新しい項目を作らず、改行して項目の本文の開始位置まで字下げする
enum ListLineBreak {
    static func edit(in string: NSString, caret: Int) -> ListContinuation.Edit? {
        let line = ListContinuation.contentRange(at: caret, in: string)
        let text = string.substring(with: line)
        guard !ListContinuation.isInCodeBlock(string, before: line.location) else { return nil }
        let marker: ListLine.Marker
        let bodyStart: Int
        if let item = ListLine.marker(of: text) {
            marker = item
            bodyStart = line.location + item.length
            // 記号の手前や途中では通常の改行にする
            guard caret >= bodyStart else { return nil }
        } else if let owner = ListLine.owner(of: text, allowsBlank: true, above: ListContinuation.linesAbove(line.location, in: string)),
                  let item = ListLine.marker(of: ListContinuation.lineText(at: owner, in: string)) {
            marker = item
            bodyStart = line.location + (ListLine.leadingWhitespace(text) as NSString).length
        } else {
            return nil
        }
        return ListContinuation.split(string, at: max(caret, bodyStart), bodyStart: bodyStart, contentEnd: NSMaxRange(line),
                                      insertion: "\n" + ListLine.continuationIndent(for: marker))
    }
}

/// コールアウトの中で Shift+Enter を押したときの書き換え。改行して、次の行にも今の行と同じ深さの `>` を付ける
enum CalloutLineBreak {
    private static let prefix = try! NSRegularExpression(pattern: #"^(?:>[ \t]?)+"#)
    private static let header = try! NSRegularExpression(pattern: #"^(?:>[ \t]?)+\[![A-Za-z-]+\]"#)

    /// カーソルがコールアウトの中（行頭の `>` より後ろ）にあれば、改行と `>` を差し込む書き換えを返す
    static func edit(in string: NSString, caret: Int) -> ListContinuation.Edit? {
        let text = string as String
        let lineRange = string.lineRange(for: NSRange(location: caret, length: 0))
        guard let match = prefix.firstMatch(in: text, range: lineRange), caret >= NSMaxRange(match.range) else { return nil }
        // 引用のブロックを上へたどり、コールアウトの見出し行があるか調べる
        var line = lineRange
        while header.firstMatch(in: text, range: line) == nil {
            guard line.location > 0 else { return nil }
            line = string.lineRange(for: NSRange(location: line.location - 1, length: 0))
            guard prefix.firstMatch(in: text, range: line) != nil else { return nil }
        }
        var quote = string.substring(with: match.range)
        if !quote.hasSuffix(" ") && !quote.hasSuffix("\t") { quote += " " }
        let insertion = "\n" + quote
        return ListContinuation.Edit(range: NSRange(location: caret, length: 0), replacement: insertion,
                                     caret: caret + (insertion as NSString).length)
    }
}
