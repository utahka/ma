import Foundation

/// 複数行の選択を、Markdown の引用記号を残した行単位のハイライトにする。
enum AICommentSelection {
    static func replacement(in text: String, range: NSRange, comment: String) -> String? {
        let source = text as NSString
        guard range.location != NSNotFound, range.length > 0,
              range.location <= source.length, range.length <= source.length - range.location else { return nil }
        let selected = source.substring(with: range)
        guard !selected.contains("==") else { return nil }
        var offset = range.location
        var highlighted = false
        let lines = selected.components(separatedBy: "\n").map { line -> String in
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
            highlighted = true
            let body = string.substring(with: NSRange(location: start, length: end - start))
            return string.substring(to: start) + "==\(body)==<!-- AI: \(comment) -->" + string.substring(from: end)
        }
        return highlighted ? lines.joined(separator: "\n") : nil
    }
}
