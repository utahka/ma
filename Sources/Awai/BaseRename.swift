import Foundation
import Yams

// MARK: - プロパティ名の変更（`.base` の参照の書き換え）

extension BaseExpression {
    /// 新しいプロパティ名として使えるか。使えなければ理由を返す。
    /// フィルタの式に素の名前（`ステータス == "完了"`）で書けるものに限る（空白や記号を含む名前は式の中で別の書き方が要るため）
    static func invalidPropertyNameReason(_ name: String) -> String? {
        if name.isEmpty { return "名前が空です" }
        if name.contains(where: { $0.isWhitespace || $0.isNewline }) { return "空白を含む名前にはできません" }
        if let character = name.first(where: { "\"'()!=<>&|,.[]:#{}`\\+*/%".contains($0) }) {
            return "「\(character)」を含む名前にはできません"
        }
        if let first = name.first, "-?*&%@".contains(first) || (first.isASCII && first.isNumber) {
            return "「\(first)」で始まる名前にはできません"
        }
        if ["file", "note", "formula", "this", "true", "false", "null"].contains(name) { return "「\(name)」は式で使う名前です" }
        return nil
    }

    /// 式の中のプロパティ `note.<old>`（素の `old`、`note.old`、`note["old"]`）を `new` に書き換えた式を返す。
    /// 字句だけを見て差し替え、ほかの文字には触れない。引用符が閉じていないなど読めない式は nil
    static func renamingProperty(in source: String, from old: String, to new: String) -> String? {
        enum Kind: Equatable { case name, string, symbol, number }
        struct Token { let kind: Kind; let range: Range<Int>; let text: String }
        let characters = Array(source)
        var tokens: [Token] = []
        var index = 0
        // BaseExpression.tokenize と同じ区切り方にする（`-` などは名前の一部）
        let symbols = ["==", "!=", ">=", "<=", "&&", "||", "!", ">", "<", "(", ")", ",", ".", "[", "]"]
        let stops = Set(" \t\n\"'()!=<>&|,.[]")
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            if character == "\"" || character == "'" {
                let start = index
                var text = ""
                var escaped = false
                index += 1
                while index < characters.count, characters[index] != character {
                    if characters[index] == "\\", index + 1 < characters.count { escaped = true; index += 1 }
                    text.append(characters[index])
                    index += 1
                }
                guard index < characters.count else { return nil }
                index += 1
                // エスケープを含む文字列は中身の位置が元の文字とずれるので、名前の候補にしない
                tokens.append(Token(kind: .string, range: start..<index, text: escaped ? "\u{0}" : text))
                continue
            }
            if character.isASCII && character.isNumber {
                var end = index + 1
                while end < characters.count, (characters[end].isASCII && characters[end].isNumber) || characters[end] == "." { end += 1 }
                tokens.append(Token(kind: .number, range: index..<end, text: String(characters[index..<end])))
                index = end
                continue
            }
            if let symbol = symbols.first(where: { String(characters[index...].prefix($0.count)) == $0 }) {
                tokens.append(Token(kind: .symbol, range: index..<(index + symbol.count), text: symbol))
                index += symbol.count
                continue
            }
            var end = index
            while end < characters.count, !stops.contains(characters[end]) { end += 1 }
            guard end > index else { return nil }
            tokens.append(Token(kind: .name, range: index..<end, text: String(characters[index..<end])))
            index = end
        }

        func token(_ i: Int) -> Token? { tokens.indices.contains(i) ? tokens[i] : nil }
        func isSymbol(_ i: Int, _ text: String) -> Bool { token(i).map { $0.kind == .symbol && $0.text == text } ?? false }
        var replacements: [(Range<Int>, String)] = []
        for (i, current) in tokens.enumerated() {
            switch current.kind {
            case .name where current.text == old:
                if isSymbol(i - 1, ".") {
                    // `note.old` だけ。`file.old` や `x.old()` は別物
                    guard token(i - 2)?.kind == .name, token(i - 2)?.text == "note", !isSymbol(i - 3, "."),
                          !isSymbol(i + 1, "(") else { continue }
                } else if isSymbol(i + 1, "(") || isSymbol(i + 1, ".") && ["file", "note", "formula"].contains(old) {
                    continue
                }
                replacements.append((current.range, new))
            case .string where current.text == old:
                // `note["old"]`
                guard isSymbol(i - 1, "["), isSymbol(i + 1, "]"), token(i - 2)?.text == "note", token(i - 2)?.kind == .name
                else { continue }
                let quote = String(characters[current.range.lowerBound])
                replacements.append((current.range, quote + new + quote))
            default:
                continue
            }
        }
        var result = characters
        for (range, text) in replacements.reversed() { result.replaceSubrange(range, with: Array(text)) }
        return String(result)
    }
}

extension BaseFile {
    /// プロパティ `old`（`note.old`）を `new` に変えた `.base` の YAML を返す。
    /// `properties:` のキー、各ビューの `order`・`columnSize`・`sort`・`groupBy`、フィルタと `formulas` の式の中の名前を書き換える。
    /// ほかの書き換えと同じく YAML 全体は書き直さず、該当する行の中の名前だけを差し替える。
    /// 書き換えたあとの YAML を読み直し、元の内容の名前だけを変えたものと一致しなければ（想定外の書き方があれば）書かずにエラーにする
    static func renamingProperty(_ yaml: String, from old: String, to new: String) throws -> String {
        if let reason = BaseExpression.invalidPropertyNameReason(new) { throw BaseError(reason) }
        let tree: [String: Any]
        do {
            tree = try Yams.load(yaml: yaml) as? [String: Any] ?? [:]
        } catch {
            throw BaseError("YAML を読めません: \(error)")
        }
        // 新しい名前をもう使っていると、列や並べ替えが2つの意味で重なる
        guard let probe = renamedTree(tree, from: new, to: old + "\u{1}") else {
            throw BaseError(".base の式を読めないため書き換えられません")
        }
        guard NSDictionary(dictionary: probe).isEqual(to: tree) else {
            throw BaseError("この .base ではすでに「\(new)」を使っています")
        }
        guard let expected = renamedTree(tree, from: old, to: new),
              let updated = renamingLines(yaml, from: old, to: new) else {
            throw BaseError(".base の書き方が想定と違うため書き換えられません")
        }
        let actual = (try? Yams.load(yaml: updated)) as? [String: Any] ?? [:]
        guard updated.components(separatedBy: "\n").count == yaml.components(separatedBy: "\n").count,
              NSDictionary(dictionary: expected).isEqual(to: actual) else {
            throw BaseError(".base の書き方が想定と違うため書き換えられません")
        }
        return updated
    }

    /// `old` / `note.old` なら書き方を保ったまま新しい名前を返す。ほかの名前は nil
    private static func renamedName(_ written: String, from old: String, to new: String) -> String? {
        if written == old { return new }
        if written == "note." + old { return "note." + new }
        return nil
    }

    /// 読み込んだ YAML の中身で名前を変える（行の書き換えの結果を確かめるため）
    private static func renamedTree(_ tree: [String: Any], from old: String, to new: String) -> [String: Any]? {
        func name(_ value: Any) -> Any {
            guard let text = value as? String else { return value }
            return renamedName(text, from: old, to: new) ?? text
        }
        func keys(_ value: Any?) -> Any? {
            guard let map = value as? [String: Any] else { return value }
            return Dictionary(map.map { (renamedName($0.key, from: old, to: new) ?? $0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        var failed = false
        func expression(_ value: Any) -> Any {
            switch value {
            case let text as String:
                guard let renamed = BaseExpression.renamingProperty(in: text, from: old, to: new) else { failed = true; return text }
                return renamed
            case let list as [Any]: return list.map(expression)
            case let map as [String: Any]: return map.mapValues(expression)
            default: return value
            }
        }
        var result = tree
        if let properties = tree["properties"] as? [String: Any] {
            // 古い名前と同じ表示名は新しい名前にする
            result["properties"] = Dictionary(properties.map { key, value -> (String, Any) in
                guard let renamed = renamedName(key, from: old, to: new) else { return (key, value) }
                guard var map = value as? [String: Any], map["displayName"] as? String == old else { return (renamed, value) }
                map["displayName"] = new
                return (renamed, map)
            }, uniquingKeysWith: { a, _ in a })
        }
        if let filters = tree["filters"] { result["filters"] = expression(filters) }
        if let formulas = tree["formulas"] as? [String: Any] { result["formulas"] = formulas.mapValues(expression) }
        if let views = tree["views"] as? [Any] {
            result["views"] = views.map { item -> Any in
                guard var view = item as? [String: Any] else { return item }
                if let order = view["order"] as? [Any] { view["order"] = order.map(name) }
                if let sizes = view["columnSize"] { view["columnSize"] = keys(sizes) }
                if let sort = view["sort"] as? [Any] {
                    view["sort"] = sort.map { key -> Any in
                        guard var key = key as? [String: Any], let property = key["property"] else { return key }
                        key["property"] = name(property)
                        return key
                    }
                }
                if var groupBy = view["groupBy"] as? [String: Any], let property = groupBy["property"] {
                    groupBy["property"] = name(property)
                    view["groupBy"] = groupBy
                }
                if let filters = view["filters"] { view["filters"] = expression(filters) }
                return view
            }
        }
        return failed ? nil : result
    }

    /// 行ごとに名前を差し替える。読めない行に古い名前があれば nil
    private static func renamingLines(_ yaml: String, from old: String, to new: String) -> String? {
        var lines = yaml.components(separatedBy: "\n")
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func isSkippable(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }
        var failed = false
        func mayContain(_ text: some StringProtocol) -> Bool { text.contains(old) }

        /// 名前1つの値（`ステータス`、`"note.ステータス"`）
        func renameName(_ raw: Substring) -> String {
            let text = raw.trimmingCharacters(in: .whitespaces)
            let (quote, body): (String, String)
            if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
                (quote, body) = (String(first), String(text.dropFirst().dropLast()))
                if body.contains("\\") || body.contains(first) { if mayContain(body) { failed = true }; return String(raw) }
            } else {
                (quote, body) = ("", text)
            }
            guard let renamed = renamedName(body, from: old, to: new) else { return String(raw) }
            let leading = raw.prefix { $0 == " " }
            let trailing = raw.reversed().prefix { $0 == " " }
            return String(leading) + quote + renamed + quote + String(trailing)
        }

        /// 式1つの値（引用符なし・一重引用符・二重引用符）
        func renameExpression(_ raw: Substring) -> String {
            let leading = String(raw.prefix { $0 == " " })
            var text = String(raw.dropFirst(leading.count))
            var trailing = ""
            while text.hasSuffix(" ") { text.removeLast(); trailing += " " }
            guard mayContain(text) else { return String(raw) }
            let expression: String
            let encode: (String) -> String
            if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
                expression = String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
                encode = { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
            } else if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
                expression = String(text.dropFirst().dropLast())
                if expression.contains("\\") || expression.contains("\"") { failed = true; return String(raw) }
                encode = { "\"" + $0 + "\"" }
            } else if let first = text.first, "'\"|>[{&*!".contains(first) {
                failed = true
                return String(raw)
            } else {
                if let comment = text.range(of: " #") {
                    trailing = String(text[comment.lowerBound...]) + trailing
                    text = String(text[..<comment.lowerBound])
                    while text.hasSuffix(" ") { text.removeLast(); trailing = " " + trailing }
                }
                expression = text
                encode = { $0 }
            }
            guard let renamed = BaseExpression.renamingProperty(in: expression, from: old, to: new) else {
                failed = true
                return String(raw)
            }
            return renamed == expression ? String(raw) : leading + encode(renamed) + trailing
        }

        /// `key: 値` のキーと、コロンの後ろ。キーを読めなければ nil
        func splitKey(_ content: Substring) -> (key: String, keyEnd: Substring.Index, rest: Substring)? {
            if let quote = content.first, quote == "\"" || quote == "'" {
                guard let close = content.dropFirst().firstIndex(of: quote) else { return nil }
                let after = content.index(after: close)
                guard content[after...].hasPrefix(":") else { return nil }
                let key = String(content[content.index(after: content.startIndex)..<close])
                if key.contains("\\") { return nil }
                return (key, after, content[content.index(after: after)...])
            }
            var search = content.startIndex
            while let colon = content[search...].firstIndex(of: ":") {
                let next = content.index(after: colon)
                if next == content.endIndex || content[next] == " " {
                    return (content[..<colon].trimmingCharacters(in: .whitespaces), colon, content[next...])
                }
                search = next
            }
            return nil
        }

        /// キーの名前を変えた行。キーの書き方（引用符）は保つ
        func renameKey(_ line: String, at depth: Int) -> String {
            let content = line.dropFirst(depth)
            guard let (key, keyEnd, _) = splitKey(content) else {
                if mayContain(content) { failed = true }
                return line
            }
            guard let renamed = renamedName(key, from: old, to: new) else { return line }
            let quoted = content.first == "\"" || content.first == "'"
            let written = quoted ? String(content.first!) + renamed + String(content.first!) : renamed
            return String(repeating: " ", count: depth) + written + content[keyEnd...]
        }

        /// フィルタの行（`- 式`、`and:`、`- or:`、字下げした式の続き）
        func renameFilterLine(_ line: String) -> String {
            let depth = indent(line)
            var content = line.dropFirst(depth)
            var prefix = String(repeating: " ", count: depth)
            while content.hasPrefix("- ") {
                prefix += "- "
                content = content.dropFirst(2)
            }
            for key in ["and", "or", "not"] where content == key + ":" || content.hasPrefix(key + ": ") {
                let rest = content.dropFirst(key.count + 1)
                return prefix + key + ":" + renameExpression(rest)
            }
            return prefix + renameExpression(content)
        }

        func renameViews(_ body: Range<Int>) {
            guard let itemIndent = body.first(where: { !isSkippable(lines[$0]) }).map({ indent(lines[$0]) }) else { return }
            let keyIndent = itemIndent + 2
            var currentKey = ""
            for line in body where !isSkippable(lines[line]) {
                let text = lines[line]
                let depth = indent(text)
                var content = text.dropFirst(depth)
                let isItem = depth == itemIndent && content.hasPrefix("- ")
                if isItem { content = content.dropFirst(2) }
                if isItem || (depth == keyIndent && !content.hasPrefix("- ")) {
                    // ビューのキーの行（`- type: table`、`order:`、`filters: 式` など）
                    guard let (key, keyEnd, rest) = splitKey(content) else {
                        if mayContain(content) { failed = true }
                        continue
                    }
                    currentKey = key
                    let value = rest.trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty else { continue }
                    let head = String(text[..<keyEnd]) + ":"
                    switch key {
                    case "filters": lines[line] = head + renameExpression(rest)
                    case "order", "columnSize", "sort", "groupBy":
                        if mayContain(value) { failed = true }
                    default: break
                    }
                    continue
                }
                // キーの値の続きの行
                switch currentKey {
                case "order":
                    guard content.hasPrefix("- ") else { if mayContain(content) { failed = true }; continue }
                    lines[line] = String(text.prefix(depth)) + "- " + renameName(content.dropFirst(2))
                case "columnSize":
                    lines[line] = renameKey(text, at: depth)
                case "sort", "groupBy":
                    var item = content
                    var prefix = String(text.prefix(depth))
                    if item.hasPrefix("- ") { item = item.dropFirst(2); prefix += "- " }
                    guard let (key, keyEnd, rest) = splitKey(item) else { if mayContain(item) { failed = true }; continue }
                    if key == "property" { lines[line] = prefix + item[..<keyEnd] + ":" + renameName(rest) }
                case "filters":
                    lines[line] = renameFilterLine(text)
                default:
                    break
                }
            }
        }

        // 最上位のキーごとに見る
        var number = 0
        while number < lines.count {
            let header = lines[number]
            guard !isSkippable(header), indent(header) == 0, let (section, _, inline) = splitKey(Substring(header)) else {
                number += 1
                continue
            }
            var end = number + 1
            while end < lines.count, isSkippable(lines[end]) || indent(lines[end]) > 0 || lines[end].hasPrefix("- ") { end += 1 }
            let body = (number + 1)..<end
            let childIndent = body.first { !isSkippable(lines[$0]) }.map { indent(lines[$0]) }
            switch section {
            case "properties":
                // 表示名が古い名前と同じなら、それも新しい名前にする（列の見出しが変わらないと名前を変えたように見えないため）
                var renamedBlock = false
                var displayIndent: Int?
                for line in body where !isSkippable(lines[line]) {
                    let depth = indent(lines[line])
                    if depth == childIndent {
                        let renamed = renameKey(lines[line], at: depth)
                        renamedBlock = renamed != lines[line]
                        displayIndent = nil
                        lines[line] = renamed
                    } else if renamedBlock, displayIndent == nil || depth == displayIndent {
                        displayIndent = depth
                        let content = lines[line].dropFirst(depth)
                        guard content.hasPrefix("displayName:"), let (_, keyEnd, rest) = splitKey(content) else { continue }
                        let written = rest.trimmingCharacters(in: .whitespaces)
                        if written == old || written == "\"\(old)\"" || written == "'\(old)'" {
                            lines[line] = String(lines[line][..<keyEnd]) + ": " + new
                        }
                    }
                }
            case "filters":
                if !inline.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines[number] = "filters:" + renameExpression(inline)
                }
                for line in body where !isSkippable(lines[line]) { lines[line] = renameFilterLine(lines[line]) }
            case "formulas":
                for line in body where !isSkippable(lines[line]) {
                    let depth = indent(lines[line])
                    if depth == childIndent, let (_, keyEnd, rest) = splitKey(lines[line].dropFirst(depth)) {
                        lines[line] = String(lines[line][..<keyEnd]) + ":" + renameExpression(rest)
                    } else if mayContain(lines[line]) {
                        failed = true
                    }
                }
            case "views":
                renameViews(body)
            default:
                // ほかのキー（`ma:` など）の中の名前は参照ではないので変えない
                break
            }
            number = end
        }

        return failed ? nil : lines.joined(separator: "\n")
    }
}
