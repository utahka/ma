import Foundation
import Yams

/// ビューの `filters:` を、`.base` に書かれたままの文字列で持つ木。フィルタの設定で編集して書き戻す
indirect enum BaseFilterNode: Equatable {
    enum Conjunction: String, CaseIterable {
        case and, or, not
    }

    case expression(String)
    case group(Conjunction, [BaseFilterNode])

    /// `.base` の `index` 番目のビューの `filters:`。ないときは nil
    static func viewFilter(in yaml: String, view index: Int) throws -> BaseFilterNode? {
        let root = try Yams.load(yaml: yaml) as? [String: Any] ?? [:]
        let views = root["views"] as? [[String: Any]] ?? []
        guard views.indices.contains(index), let node = views[index]["filters"] else { return nil }
        return try BaseFilterNode(node)
    }

    init(_ node: Any) throws {
        if let map = node as? [String: Any], map.count == 1, let (key, value) = map.first,
           let conjunction = Conjunction(rawValue: key) {
            self = .group(conjunction, try (value as? [Any] ?? [value]).map(BaseFilterNode.init))
        } else if node is [String: Any] || node is [Any] {
            throw BaseError("フィルタを読めません: \(node)")
        } else {
            self = .expression("\(node)")
        }
    }

    /// `filters:` の値の行。`column` は `and:` などのキーを置く字下げ
    func lines(column: Int) -> [String] {
        let pad = String(repeating: " ", count: column)
        switch self {
        case .expression(let text):
            return [pad + BaseFilterNode.scalar(text)]
        case .group(let conjunction, let children):
            return [pad + conjunction.rawValue + ":" + (children.isEmpty ? " []" : "")] + children.flatMap { $0.item(column: column + 2) }
        }
    }

    /// リストの項目（`- 式` / `- or:` と、その下の項目）
    private func item(column: Int) -> [String] {
        let pad = String(repeating: " ", count: column)
        var lines = lines(column: column + 2)
        lines[0] = pad + "- " + lines[0].dropFirst(column + 2)
        return lines
    }

    /// Obsidian（JavaScript の yaml）と同じ書き方にする。引用符なしで読める文字列はそのまま、
    /// 囲むときは二重引用符。中に `"` があって `'` がなければ一重引用符（`'!ステータス.contains("完了")'`）
    static func scalar(_ text: String) -> String {
        let reserved: Set<String> = ["", "~", "null", "Null", "NULL", "true", "True", "TRUE", "false", "False", "FALSE"]
        let plain = !reserved.contains(text) && Double(text) == nil
            && !text.contains(": ") && !text.contains(" #") && !text.hasSuffix(":") && !text.contains("\n")
            && text.first.map { "-?:,[]{}#&*!|>'\"%@`".contains($0) } == false
            && text == text.trimmingCharacters(in: .whitespaces)
        if plain { return text }
        if text.contains("\""), !text.contains("'"), !text.contains("\n") { return "'" + text + "'" }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + escaped + "\""
    }
}

// MARK: - GUI で扱える条件

/// `ステータス.contains("完了")` のような、プロパティ・演算子・値の1つの条件
struct BaseFilterCondition: Equatable {
    enum Operator: CaseIterable {
        case equals, notEquals, contains, notContains, isEmpty, isNotEmpty, greater, less, greaterOrEqual, lessOrEqual

        var title: String {
            switch self {
            case .equals: "が次と等しい"
            case .notEquals: "が次と等しくない"
            case .contains: "が次を含む"
            case .notContains: "が次を含まない"
            case .isEmpty: "が空"
            case .isNotEmpty: "が空でない"
            case .greater: "が次より大きい"
            case .less: "が次より小さい"
            case .greaterOrEqual: "が次以上"
            case .lessOrEqual: "が次以下"
            }
        }

        var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }

        fileprivate var symbol: String? {
            switch self {
            case .equals: "=="
            case .notEquals: "!="
            case .greater: ">"
            case .less: "<"
            case .greaterOrEqual: ">="
            case .lessOrEqual: "<="
            default: nil
            }
        }
    }

    /// `.base` に書く名前（`ステータス`、`file.folder` など）
    var property: String
    var op: Operator
    var value: String

    /// 式の文字列が GUI の1行で表せる形なら、その条件
    init?(_ text: String) {
        guard let expression = try? BaseExpression.parse(text) else { return nil }
        func name(_ id: String) -> String { id.hasPrefix("note.") ? String(id.dropFirst(5)) : id }
        func literal(_ value: BaseValue) -> String? {
            switch value {
            case .string(let text): text
            case .number: value.text
            default: nil
            }
        }
        switch expression {
        case .binary(let symbol, .property(let id), .literal(let value)):
            guard let op = Operator.allCases.first(where: { $0.symbol == symbol }), let value = literal(value) else { return nil }
            self.init(property: name(id), op: op, value: value)
        case .method(.property(let id), "contains", let arguments):
            guard arguments.count == 1, case .literal(let value) = arguments[0], let value = literal(value) else { return nil }
            self.init(property: name(id), op: .contains, value: value)
        case .not(.method(.property(let id), "contains", let arguments)):
            guard arguments.count == 1, case .literal(let value) = arguments[0], let value = literal(value) else { return nil }
            self.init(property: name(id), op: .notContains, value: value)
        case .method(.property(let id), "isEmpty", let arguments) where arguments.isEmpty:
            self.init(property: name(id), op: .isEmpty, value: "")
        case .not(.method(.property(let id), "isEmpty", let arguments)) where arguments.isEmpty:
            self.init(property: name(id), op: .isNotEmpty, value: "")
        default:
            return nil
        }
    }

    init(property: String, op: Operator, value: String) {
        self.property = property
        self.op = op
        self.value = value
    }

    /// 式の文字列。値が要る演算子で値が空なら nil（書きかけの行は保存しない）
    var expression: String? {
        if op.needsValue, value.isEmpty { return nil }
        let name = Self.reference(property)
        let literal = Self.isNumber(value) ? value : "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        switch op {
        case .contains: return "\(name).contains(\(literal))"
        case .notContains: return "!\(name).contains(\(literal))"
        case .isEmpty: return "\(name).isEmpty()"
        case .isNotEmpty: return "!\(name).isEmpty()"
        default: return "\(name) \(op.symbol!) \(literal)"
        }
    }

    private static func isNumber(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } && Double(text) != nil
    }

    /// 式の中の名前。区切りの文字を含む名前は `note["名前"]` と書く
    private static func reference(_ property: String) -> String {
        let stops = Set(" \t\n\"'()!=<>&|,.[]")
        if property.hasPrefix("file.") || property.hasPrefix("formula.") { return property }
        let key = property.hasPrefix("note.") ? String(property.dropFirst(5)) : property
        let reserved = ["file", "note", "formula", "true", "false", "null"]
        if key.contains(where: stops.contains) || reserved.contains(key) || key.first.map({ $0.isASCII && $0.isNumber }) == true {
            return "note[\"" + key.replacingOccurrences(of: "\"", with: "\\\"") + "\"]"
        }
        return property
    }
}

// MARK: - ビューのフィルタの書き戻し

extension BaseFile {
    /// `views` の `index` 番目のビューの `filters:` を書き換えた YAML を返す。`filter` が nil ならキーごと消す。
    /// `updatingColumns` と同じく、YAML 全体は書き直さず、そのキーの行だけを差し替える。形が想定と違えば nil
    static func updatingFilter(_ yaml: String, view index: Int, filter: BaseFilterNode?) -> String? {
        var lines = yaml.components(separatedBy: "\n")
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

        guard let viewsLine = lines.firstIndex(of: "views:") else { return nil }
        var items: [Int] = []
        var itemIndent: Int?
        var end = lines.count
        for number in (viewsLine + 1)..<lines.count {
            let line = lines[number]
            if isBlank(line) { continue }
            let depth = indent(line)
            if depth == 0 { end = number; break }
            if line.dropFirst(depth).hasPrefix("- ") {
                if itemIndent == nil { itemIndent = depth }
                if depth == itemIndent { items.append(number) }
            }
        }
        guard let itemIndent, items.indices.contains(index) else { return nil }
        let start = items[index]
        var itemEnd = index + 1 < items.count ? items[index + 1] : end
        while itemEnd > start + 1, isBlank(lines[itemEnd - 1]) { itemEnd -= 1 }
        let keyIndent = itemIndent + 2
        func isKey(_ number: Int, _ key: String) -> Bool {
            indent(lines[number]) == keyIndent && lines[number].dropFirst(keyIndent).hasPrefix(key + ":")
        }
        // 項目の先頭の行（`- filters:`）にある形は扱わない
        if lines[start].dropFirst(itemIndent + 2).hasPrefix("filters:") { return nil }

        let replacement = filter.map { [String(repeating: " ", count: keyIndent) + "filters:"] + $0.lines(column: keyIndent + 2) } ?? []
        if let keyLine = ((start + 1)..<itemEnd).first(where: { isKey($0, "filters") }) {
            var last = keyLine + 1
            while last < itemEnd, isBlank(lines[last]) || indent(lines[last]) > keyIndent
                || (indent(lines[last]) == keyIndent && lines[last].dropFirst(keyIndent).hasPrefix("- ")) {
                last += 1
            }
            // 値の後ろの空行は残す
            while last > keyLine + 1, isBlank(lines[last - 1]) { last -= 1 }
            lines.replaceSubrange(keyLine..<last, with: replacement)
        } else if !replacement.isEmpty {
            // Obsidian と同じく `name:` の次に置く
            let nameLine = (start..<itemEnd).first { number in
                number == start ? lines[number].dropFirst(itemIndent + 2).hasPrefix("name:") : isKey(number, "name")
            }
            let at = nameLine.map { $0 + 1 } ?? start + 1
            lines.insert(contentsOf: replacement, at: at)
        }
        return lines.joined(separator: "\n")
    }
}
