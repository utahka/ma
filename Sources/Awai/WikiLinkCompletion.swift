import Foundation

/// ウィキリンク入力中の範囲と候補。ファイルは作成せず、vault の既存ノートだけを使う。
enum WikiLinkCompletion {
    struct Context {
        let start: Int
        let query: String
        let range: NSRange
    }

    static func context(in text: String, selection: NSRange) -> Context? {
        let string = text as NSString
        guard selection.length == 0, selection.location <= string.length,
              selection.location != NSNotFound else { return nil }
        let caret = selection.location
        let line = string.lineRange(for: selection)
        let before = string.substring(with: NSRange(location: line.location, length: caret - line.location))
        guard let opening = before.range(of: "[[", options: .backwards) else { return nil }
        let query = String(before[opening.upperBound...])
        guard !query.contains(where: { "]|#\n\r".contains($0) }) else { return nil }
        let prefix = before[..<opening.lowerBound]
        guard prefix.filter({ $0 == "`" }).count % 2 == 0 else { return nil }
        // コードブロックでは候補を出さない。引用内のフェンスも扱う。
        var fence: Character?
        var fenceLength = 0
        for raw in string.substring(to: line.location).components(separatedBy: "\n") {
            let content = raw.replacingOccurrences(of: #"^[ \t]*(?:>[ \t]*)*"#, with: "", options: .regularExpression)
            guard let first = content.first, first == "`" || first == "~" else { continue }
            let count = content.prefix { $0 == first }.count
            guard count >= 3 else { continue }
            if fence == nil { fence = first; fenceLength = count }
            else if fence == first, count >= fenceLength,
                    content.dropFirst(count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fence = nil }
        }
        guard fence == nil else { return nil }
        let start = line.location + NSRange(opening, in: before).location
        return Context(start: start, query: query, range: NSRange(location: start, length: caret - start))
    }

    static func matching(_ query: String, paths: [String]) -> [String] {
        func key(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }
        let wanted = key(query)
        let sorted = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let matches = sorted.filter { key($0).contains(wanted) }
        let preferred = matches.filter { key(($0 as NSString).lastPathComponent).hasPrefix(wanted) }
        return preferred + matches.filter { !key(($0 as NSString).lastPathComponent).hasPrefix(wanted) }
    }

    static func edit(in text: String, selection: NSRange, path: String) -> (range: NSRange, text: String)? {
        guard let context = context(in: text, selection: selection) else { return nil }
        let string = text as NSString
        let line = string.lineRange(for: selection)
        let suffix = string.substring(with: NSRange(location: selection.location, length: NSMaxRange(line) - selection.location))
        var end = selection.location
        if let closing = suffix.range(of: "]]"), !suffix[..<closing.lowerBound].contains("[[") {
            end += NSRange(closing, in: suffix).location + 2
        }
        return (NSRange(location: context.start, length: end - context.start), "[[\(path)]]")
    }
}
