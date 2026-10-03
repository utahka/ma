import Foundation

/// プロパティの値。Obsidian のプロパティで使う形（1つの値・リスト）だけを扱い、
/// 入れ子の辞書や複数行の文字列などは `other` として元の文字のまま残す
enum PropertyValue: Equatable {
    case scalar(String)
    case list([String])
    case other

    var text: String {
        switch self {
        case .scalar(let value): value
        case .list(let items): items.joined(separator: ", ")
        case .other: ""
        }
    }
}

/// フロントマターの1つのプロパティ。`range` はキーの行から値の最後の行まで（改行を含む）
struct FrontmatterEntry: Equatable {
    let key: String
    let value: PropertyValue
    let range: NSRange
}

/// ノートの先頭の `---` で囲んだプロパティ。書き換えは該当するプロパティの行だけを差し替える形で返し、
/// ほかの行（コメントや Awai が解釈しない書き方）には触れない
struct Frontmatter: Equatable {
    /// 先頭の `---` から閉じの `---` の行末（改行を含む）まで
    let range: NSRange
    /// 閉じの `---` の行の先頭。新しいプロパティはここに足す
    let closingLocation: Int
    let entries: [FrontmatterEntry]

    func entry(_ key: String) -> FrontmatterEntry? { entries.first { $0.key == key } }

    /// 文書の先頭にフロントマターがあれば読む
    static func parse(_ text: String) -> Frontmatter? {
        let string = text as NSString
        guard string.length >= 3, string.hasPrefix("---") else { return nil }
        var lines: [NSRange] = []
        var position = 0
        while position < string.length {
            let line = string.lineRange(for: NSRange(location: position, length: 0))
            lines.append(line)
            position = NSMaxRange(line)
        }
        func content(_ index: Int) -> String {
            string.substring(with: lines[index]).trimmingCharacters(in: .newlines)
        }
        guard content(0).trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.indices.dropFirst().first(where: { content($0).trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        var entries: [FrontmatterEntry] = []
        var index = 1
        while index < closing {
            let line = content(index)
            guard let (key, rest) = splitKey(line) else { index += 1; continue }
            // 字下げした行と、行頭の `- ` のリストはこのプロパティの続き
            var end = index + 1
            while end < closing {
                let next = content(end)
                guard next.hasPrefix(" ") || next.hasPrefix("\t") || next.hasPrefix("- ") || next == "-" else { break }
                end += 1
            }
            let continuation = (index + 1..<end).map(content)
            entries.append(FrontmatterEntry(
                key: key, value: decodeValue(rest, continuation: continuation),
                range: NSRange(location: lines[index].location, length: NSMaxRange(lines[end - 1]) - lines[index].location)
            ))
            index = end
        }
        return Frontmatter(
            range: NSRange(location: 0, length: NSMaxRange(lines[closing])),
            closingLocation: lines[closing].location, entries: entries
        )
    }

    // MARK: - 書き換え

    /// 文書の置き換え。`range` を `replacement` に差し替える
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
    }

    /// 空のフロントマターを文書の先頭に足す
    static let emptyBlock = "---\n---\n"

    /// 文書のプロパティの値を設定した文書を返す。フロントマターがなければ先頭に作る
    static func setting(_ key: String, to value: PropertyValue, type: PropertyType, in text: String) -> String {
        let text = parse(text) == nil ? emptyBlock + text : text
        guard let edit = parse(text)?.setting(key, to: value, type: type) else { return text }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    /// プロパティの値を設定する。なければ末尾に足す
    func setting(_ key: String, to value: PropertyValue, type: PropertyType) -> Edit {
        let lines = Self.encode(key: key, value: value, type: type)
        if let entry = entry(key) {
            // 閉じの `---` より前の行なので、範囲は必ず改行で終わる
            return Edit(range: entry.range, replacement: lines + "\n")
        }
        return Edit(range: NSRange(location: closingLocation, length: 0), replacement: lines + "\n")
    }

    func removing(_ key: String) -> Edit? {
        guard let entry = entry(key) else { return nil }
        return Edit(range: entry.range, replacement: "")
    }

    /// キーの名前だけを変える。値の行はそのまま残す
    func renaming(_ key: String, to newKey: String, in text: String) -> Edit? {
        guard let entry = entry(key) else { return nil }
        let string = text as NSString
        let colon = string.range(of: ":", range: entry.range)
        guard colon.location != NSNotFound else { return nil }
        return Edit(range: NSRange(location: entry.range.location, length: colon.location - entry.range.location),
                    replacement: Self.encodeKey(newKey))
    }

    // MARK: - 読み取り

    private static func splitKey(_ line: String) -> (String, String)? {
        guard let first = line.first, first != " ", first != "\t", first != "#", first != "-" else { return nil }
        var key: String
        var rest: Substring
        if first == "\"" || first == "'" {
            // 引用符で囲んだキー
            let body = line.dropFirst()
            guard let close = body.firstIndex(of: first) else { return nil }
            key = String(body[..<close])
            rest = body[body.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            rest = rest.dropFirst()
        } else {
            guard let colon = line.range(of: ":") else { return nil }
            key = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            rest = line[colon.upperBound...]
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        }
        return (key, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func decodeValue(_ rest: String, continuation: [String]) -> PropertyValue {
        let items = continuation.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if rest.isEmpty {
            if items.isEmpty { return .scalar("") }
            guard items.allSatisfy({ $0 == "-" || $0.hasPrefix("- ") }) else { return .other }
            return .list(items.map { decodeScalar(String($0.dropFirst()).trimmingCharacters(in: .whitespaces)) })
        }
        guard items.isEmpty else { return .other }
        if rest.hasPrefix("|") || rest.hasPrefix(">") || rest.hasPrefix("{") { return .other }
        if rest.hasPrefix("[") {
            guard rest.hasSuffix("]") else { return .other }
            let inner = rest.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            return .list(inner.isEmpty ? [] : splitFlow(inner).map(decodeScalar))
        }
        return .scalar(decodeScalar(rest))
    }

    /// `[a, "b, c"]` の中身をカンマで分ける（引用符の中のカンマでは分けない）
    private static func splitFlow(_ inner: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in inner {
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    private static func decodeScalar(_ raw: String) -> String {
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            var result = ""
            var escaping = false
            for character in raw.dropFirst().dropLast() {
                if escaping {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(character)
                    }
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        // 引用符なしの値の後ろのコメント（` #` から後ろ）は値に含めない
        if let comment = raw.range(of: " #") { return String(raw[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return raw
    }

    // MARK: - 書き出し

    /// Obsidian と同じ形で書く。リストは `  - 項目` を1行ずつ並べ、空の値は `key:` だけにする
    static func encode(key: String, value: PropertyValue, type: PropertyType) -> String {
        let name = encodeKey(key)
        switch value {
        case .scalar(let text):
            if text.isEmpty { return name + ":" }
            let raw = type == .number || type == .checkbox || !needsQuotes(text)
            return "\(name): \(raw ? text : quoted(text))"
        case .list(let items):
            if items.isEmpty { return name + ":" }
            return ([name + ":"] + items.map { "  - " + (needsQuotes($0) ? quoted($0) : $0) }).joined(separator: "\n")
        case .other:
            return name + ":"
        }
    }

    static func encodeKey(_ key: String) -> String {
        key.contains(":") || key.hasPrefix("#") || key.hasPrefix("-") || key.hasPrefix(" ") ? quoted(key) : key
    }

    /// 引用符なしでは文字列として読めない値。`[[リンク]]` も YAML ではリストになってしまうので囲む
    private static func needsQuotes(_ text: String) -> Bool {
        if text != text.trimmingCharacters(in: .whitespaces) { return true }
        if text.contains(": ") || text.contains(" #") || text.hasSuffix(":") || text.contains("\n") { return true }
        if let first = text.first, "-?:,[]{}#&*!|>'\"%@`".contains(first) {
            // `-` で始まる値でも、`-5` のような数や `- ` でないものは残す
            return !(first == "-" && text.count > 1 && !text.hasPrefix("- "))
        }
        let lower = text.lowercased()
        if ["true", "false", "yes", "no", "null", "~", "on", "off"].contains(lower) { return true }
        return Double(text) != nil
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
