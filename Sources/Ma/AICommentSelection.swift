import Foundation

/// 引用記号を残して行ごとにハイライトし、複数行のコメント本文は末尾に1回だけ保存する。
enum AICommentSelection {
    static func replacement(in text: String, range: NSRange, comment: String) -> String? {
        let source = text as NSString
        guard range.location != NSNotFound, range.length > 0,
              range.location <= source.length, range.length <= source.length - range.location else { return nil }
        let selected = source.substring(with: range)
        guard !selected.contains("=="), !selected.contains("<!-- AI:") else { return nil }
        var offset = range.location
        var highlightedLines: [Int] = []
        var lines = selected.components(separatedBy: "\n").enumerated().map { index, line -> String in
            defer { offset += (line as NSString).length + 1 }
            let string = line as NSString
            var start = 0
            // 選択が行頭から始まる場合だけ、引用の記号をハイライトから外す。
            if source.lineRange(for: NSRange(location: offset, length: 0)).location == offset,
               let quote = line.range(of: #"^[ \t]*(?:>[ \t]*)+"#, options: .regularExpression) {
                start = NSRange(quote, in: line).length
            }
            var end = string.length
            let whitespace = CharacterSet.whitespacesAndNewlines
            func isSpace(_ index: Int) -> Bool {
                string.substring(with: NSRange(location: index, length: 1)).unicodeScalars.allSatisfy(whitespace.contains)
            }
            while start < end, isSpace(start) { start += 1 }
            while end > start, isSpace(end - 1) { end -= 1 }
            guard start < end else { return line }
            highlightedLines.append(index)
            let body = string.substring(with: NSRange(location: start, length: end - start))
            return string.substring(to: start) + "==\(body)==" + string.substring(from: end)
        }
        guard let first = highlightedLines.first, let last = highlightedLines.last else { return nil }
        // 閉じるハイライトの直後に置く。行末の空白や CRLF は元のまま残す。
        func appendMarker(_ marker: String, to index: Int) {
            let close = lines[index].range(of: "==", options: .backwards)!
            lines[index].insert(contentsOf: marker, at: close.upperBound)
        }
        if first != last { appendMarker("<!-- AI:start -->", to: first) }
        appendMarker("<!-- AI: \(comment) -->", to: last)
        return lines.joined(separator: "\n")
    }
}

/// 複数行コメントの範囲。従来の1行コメントは MarkdownStyler がそのまま読む。
extension AICommentSelection {
    struct Group {
        let range: NSRange
        let bodies: [NSRange]
        let markers: [NSRange]
        let comment: String
    }

    static func groups(in text: String) -> [Group] {
        let string = text as NSString
        let whole = NSRange(location: 0, length: string.length)
        let pattern = try! NSRegularExpression(pattern: #"==(?=\S)(?:(?!==)[^\n])+?(?<=\S)==(<!-- AI:start -->)((?:(?!<!-- AI:start -->)[\s\S])*?)(<!--\s*AI:\s*([^\n]*?)\s*-->)"#)
        let highlight = try! NSRegularExpression(pattern: #"==(?=\S)((?:(?!==)[^\n])+?)(?<=\S)=="#)
        // コード例の中の記法を実際のコメントとして読まない。
        let inlineCode = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
        var excluded = inlineCode.matches(in: text, range: whole).map(\.range)
        var fenceStart: Int?
        var fenceCharacter: unichar = 0
        var fenceLength = 0
        var offset = 0
        while offset < string.length {
            let line = string.lineRange(for: NSRange(location: offset, length: 0))
            let content = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = content.utf16.first, first == 96 || first == 126 {
                let count = content.utf16.prefix { $0 == first }.count
                if count >= 3 {
                    if fenceStart == nil { fenceStart = offset; fenceCharacter = first; fenceLength = count }
                    else if first == fenceCharacter, count >= fenceLength,
                            content.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                        excluded.append(NSRange(location: fenceStart!, length: NSMaxRange(line) - fenceStart!))
                        fenceStart = nil
                    }
                }
            }
            offset = NSMaxRange(line)
        }
        if let fenceStart { excluded.append(NSRange(location: fenceStart, length: string.length - fenceStart)) }
        return pattern.matches(in: text, range: whole).compactMap { match in
            guard !excluded.contains(where: {
                NSLocationInRange(match.range.location, $0)
                    || NSLocationInRange(match.range(at: 1).location, $0)
                    || NSLocationInRange(match.range(at: 3).location, $0)
            }) else { return nil }
            let bodyRange = NSRange(location: match.range.location, length: match.range(at: 3).location - match.range.location)
            let highlights = highlight.matches(in: text, range: bodyRange)
            guard highlights.count > 1 else { return nil }
            return Group(range: match.range, bodies: highlights.map { $0.range(at: 1) },
                         markers: [match.range(at: 1), match.range(at: 3)],
                         comment: string.substring(with: match.range(at: 4)))
        }
    }
}
