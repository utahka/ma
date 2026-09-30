import Foundation

/// リスト項目の中で Enter を押したときの書き換え。次の行に同じ種類の項目を作り、空の項目なら記号を消してリストを抜ける。
/// 画面に依存しないので swiftc で単体確認できる
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
        guard !isInCodeBlock(string, before: lineRange.location),
              let match = pattern.firstMatch(in: string as String, range: line)
        else { return nil }
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

        // 中身が空の項目: 記号とインデントを消してリストを抜ける（引用の `>` は残す）
        if body.trimmingCharacters(in: .whitespaces).isEmpty {
            let range = NSRange(location: line.location + (quote as NSString).length,
                                length: contentEnd - line.location - (quote as NSString).length)
            return Edit(range: range, replacement: "", caret: range.location)
        }

        var marker: String
        if let bullet = text(3) {
            marker = bullet
        } else if let number = text(4).flatMap({ Int($0) }), let delimiter = text(5) {
            marker = "\(number + 1)\(delimiter)"
        } else {
            return nil
        }
        marker += text(6) ?? " "
        if text(7) != nil { marker += "[ ] " }

        // カーソルの後ろの文字は新しい項目へ送る。境目の空白は落とす
        var cut = caret
        while cut > markerEnd, [0x20, 0x09].contains(string.character(at: cut - 1)) { cut -= 1 }
        var rest = caret
        while rest < contentEnd, [0x20, 0x09].contains(string.character(at: rest)) { rest += 1 }
        let insertion = "\n" + quote + indent + marker
        return Edit(range: NSRange(location: cut, length: rest - cut),
                    replacement: insertion,
                    caret: cut + (insertion as NSString).length)
    }

    /// 行頭の ``` / ~~~ の数を数え、コードブロックの中かを調べる
    private static func isInCodeBlock(_ string: NSString, before location: Int) -> Bool {
        var inside = false
        string.substring(to: location).enumerateLines { line, _ in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inside.toggle() }
        }
        return inside
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
