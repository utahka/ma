import Foundation

/// `.base` の式で扱う値
enum BaseValue: Equatable {
    case null
    case string(String)
    case number(Double)
    case bool(Bool)
    case date(Date)
    case list([BaseValue])

    var isEmpty: Bool {
        switch self {
        case .null: true
        case .string(let text): text.isEmpty
        case .list(let items): items.isEmpty
        default: false
        }
    }

    var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0
        default: !isEmpty
        }
    }

    /// 表のセルや比較に使う文字列
    var text: String {
        switch self {
        case .null: ""
        case .string(let text): text
        case .number(let value): value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        case .date(let date): BaseValue.dateFormatter.string(from: date)
        case .list(let items): items.map(\.text).joined(separator: ", ")
        }
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 並べ替えの比較。空の値は常に後ろに回すので、ここでは扱わない
    static func compare(_ a: BaseValue, _ b: BaseValue) -> ComparisonResult {
        switch (a, b) {
        case (.number(let x), .number(let y)): x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        case (.date(let x), .date(let y)): x.compare(y)
        case (.bool(let x), .bool(let y)): x == y ? .orderedSame : (!x ? .orderedAscending : .orderedDescending)
        default: a.text.localizedStandardCompare(b.text)
        }
    }

    static func equal(_ a: BaseValue, _ b: BaseValue) -> Bool {
        switch (a, b) {
        case (.null, _), (_, .null): a.isEmpty && b.isEmpty
        case (.list, .list): a == b
        case (.list, _), (_, .list): false
        case (.number(let x), .number(let y)): x == y
        default: a.text == b.text
        }
    }
}

struct BaseError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// 式を評価するときに、プロパティの値を渡す相手
protocol BaseContext {
    /// `note.ステータス` `file.name` のような ID の値
    func value(of property: String) -> BaseValue
    /// `file.hasTag("x")` のような file の関数
    func fileFunction(_ name: String, _ arguments: [BaseValue]) throws -> BaseValue
}

/// Bases のフィルタの式。Obsidian の式のうち、比較・論理演算・よく使う関数だけを扱う
indirect enum BaseExpression {
    case literal(BaseValue)
    case property(String)
    case not(BaseExpression)
    case binary(String, BaseExpression, BaseExpression)
    case method(BaseExpression, String, [BaseExpression])
    case fileFunction(String, [BaseExpression])

    /// 列の ID（`ステータス` は `note.ステータス` とみなす）
    static func propertyID(_ name: String) -> String {
        name.hasPrefix("note.") || name.hasPrefix("file.") || name.hasPrefix("formula.") ? name : "note." + name
    }

    // MARK: - 評価

    func evaluate(_ context: BaseContext) throws -> BaseValue {
        switch self {
        case .literal(let value):
            return value
        case .property(let id):
            return context.value(of: id)
        case .not(let expression):
            return .bool(!(try expression.evaluate(context).isTruthy))
        case .binary(let op, let left, let right):
            if op == "&&" { return .bool(try left.evaluate(context).isTruthy && right.evaluate(context).isTruthy) }
            if op == "||" { return .bool(try left.evaluate(context).isTruthy || right.evaluate(context).isTruthy) }
            let a = try left.evaluate(context)
            let b = try right.evaluate(context)
            switch op {
            case "==": return .bool(BaseValue.equal(a, b))
            case "!=": return .bool(!BaseValue.equal(a, b))
            case ">", "<", ">=", "<=":
                if a.isEmpty || b.isEmpty { return .bool(false) }
                let order = BaseValue.compare(Self.numeric(a) ?? a, Self.numeric(b) ?? b)
                switch op {
                case ">": return .bool(order == .orderedDescending)
                case "<": return .bool(order == .orderedAscending)
                case ">=": return .bool(order != .orderedAscending)
                default: return .bool(order != .orderedDescending)
                }
            default:
                throw BaseError("対応していない演算子: \(op)")
            }
        case .method(let receiver, let name, let arguments):
            return try Self.call(name, on: receiver.evaluate(context), arguments.map { try $0.evaluate(context) })
        case .fileFunction(let name, let arguments):
            return try context.fileFunction(name, arguments.map { try $0.evaluate(context) })
        }
    }

    /// 数として読める文字列は数として比べる（`ID > 10` など）
    private static func numeric(_ value: BaseValue) -> BaseValue? {
        if case .string(let text) = value, let number = Double(text) { return .number(number) }
        return nil
    }

    private static func call(_ name: String, on value: BaseValue, _ arguments: [BaseValue]) throws -> BaseValue {
        func items() -> [BaseValue] {
            if case .list(let items) = value { return items }
            return value.isEmpty ? [] : [value]
        }
        func contains(_ needle: BaseValue) -> Bool {
            switch value {
            case .list(let items): items.contains { BaseValue.equal($0, needle) }
            case .null: false
            default: value.text.contains(needle.text)
            }
        }
        switch name {
        case "isEmpty": return .bool(value.isEmpty)
        case "isTruthy": return .bool(value.isTruthy)
        case "contains": return .bool(arguments.first.map(contains) ?? false)
        case "containsAny": return .bool(arguments.contains(where: contains))
        case "containsAll": return .bool(arguments.allSatisfy(contains))
        case "startsWith": return .bool(arguments.first.map { value.text.hasPrefix($0.text) } ?? false)
        case "endsWith": return .bool(arguments.first.map { value.text.hasSuffix($0.text) } ?? false)
        case "lower": return .string(value.text.lowercased())
        case "upper": return .string(value.text.uppercased())
        case "trim": return .string(value.text.trimmingCharacters(in: .whitespaces))
        case "toString": return .string(value.text)
        case "length": return .number(Double(value.isList ? items().count : value.text.count))
        default: throw BaseError("対応していない関数: \(name)()")
        }
    }

    // MARK: - 解析

    static func parse(_ source: String) throws -> BaseExpression {
        var parser = Parser(tokens: try tokenize(source))
        let expression = try parser.parseOr()
        guard parser.atEnd else { throw BaseError("式を読めません: \(source)") }
        return expression
    }

    fileprivate enum Token: Equatable {
        case string(String)
        case number(Double)
        case name(String)
        case symbol(String)
    }

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let characters = Array(source)
        var index = 0
        let symbols = ["==", "!=", ">=", "<=", "&&", "||", "!", ">", "<", "(", ")", ",", ".", "[", "]"]
        let stops = Set(" \t\n\"'()!=<>&|,.[]")
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            if character == "\"" || character == "'" {
                var text = ""
                index += 1
                while index < characters.count, characters[index] != character {
                    if characters[index] == "\\", index + 1 < characters.count { index += 1 }
                    text.append(characters[index])
                    index += 1
                }
                guard index < characters.count else { throw BaseError("引用符が閉じていません: \(source)") }
                index += 1
                tokens.append(.string(text))
                continue
            }
            if let symbol = symbols.first(where: { String(characters[index...].prefix($0.count)) == $0 }) {
                tokens.append(.symbol(symbol))
                index += symbol.count
                continue
            }
            // 漢数字なども isNumber になるので、ASCII の数字だけを数とみなす
            if character.isASCII && character.isNumber
                || (character == "-" && index + 1 < characters.count && characters[index + 1].isASCII && characters[index + 1].isNumber) {
                var end = index + 1
                while end < characters.count, (characters[end].isASCII && characters[end].isNumber) || characters[end] == "." { end += 1 }
                if let number = Double(String(characters[index..<end])) {
                    tokens.append(.number(number))
                    index = end
                    continue
                }
            }
            var end = index
            while end < characters.count, !stops.contains(characters[end]) { end += 1 }
            guard end > index else { throw BaseError("読めない文字「\(character)」: \(source)") }
            tokens.append(.name(String(characters[index..<end])))
            index = end
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0

        var atEnd: Bool { position == tokens.count }

        private func peek() -> Token? { position < tokens.count ? tokens[position] : nil }

        private mutating func take(_ symbol: String) -> Bool {
            guard peek() == .symbol(symbol) else { return false }
            position += 1
            return true
        }

        private mutating func expect(_ symbol: String) throws {
            guard take(symbol) else { throw BaseError("「\(symbol)」がありません") }
        }

        mutating func parseOr() throws -> BaseExpression {
            var left = try parseAnd()
            while take("||") { left = .binary("||", left, try parseAnd()) }
            return left
        }

        private mutating func parseAnd() throws -> BaseExpression {
            var left = try parseComparison()
            while take("&&") { left = .binary("&&", left, try parseComparison()) }
            return left
        }

        private mutating func parseComparison() throws -> BaseExpression {
            let left = try parseUnary()
            for op in ["==", "!=", ">=", "<=", ">", "<"] where take(op) {
                return .binary(op, left, try parseUnary())
            }
            return left
        }

        private mutating func parseUnary() throws -> BaseExpression {
            if take("!") { return .not(try parseUnary()) }
            return try parsePostfix()
        }

        private mutating func parsePostfix() throws -> BaseExpression {
            var expression = try parsePrimary()
            while true {
                if take(".") {
                    guard case .name(let name)? = peek() else { throw BaseError("「.」の後ろに名前がありません") }
                    position += 1
                    if take("(") {
                        let arguments = try parseArguments()
                        if case .property("file") = expression {
                            expression = .fileFunction(name, arguments)
                        } else {
                            expression = .method(expression, name, arguments)
                        }
                    } else if case .property(let scope) = expression, ["file", "note", "formula"].contains(scope) {
                        expression = .property(scope + "." + name)
                    } else if name == "length" {
                        expression = .method(expression, "length", [])
                    } else {
                        throw BaseError("対応していない参照: .\(name)")
                    }
                } else if take("[") {
                    // note["名前"] の形
                    guard case .property(let scope) = expression, case .string(let name)? = peek() else {
                        throw BaseError("対応していない「[ ]」の使い方です")
                    }
                    position += 1
                    try expect("]")
                    expression = .property(scope + "." + name)
                } else {
                    return expression
                }
            }
        }

        private mutating func parseArguments() throws -> [BaseExpression] {
            var arguments: [BaseExpression] = []
            if take(")") { return arguments }
            repeat { arguments.append(try parseOr()) } while take(",")
            try expect(")")
            return arguments
        }

        private mutating func parsePrimary() throws -> BaseExpression {
            guard let token = peek() else { throw BaseError("式が途中で終わっています") }
            position += 1
            switch token {
            case .string(let text): return .literal(.string(text))
            case .number(let number): return .literal(.number(number))
            case .symbol("("):
                let inner = try parseOr()
                try expect(")")
                return inner
            case .name("true"): return .literal(.bool(true))
            case .name("false"): return .literal(.bool(false))
            case .name("null"): return .literal(.null)
            case .name(let name):
                // file・note・formula は後ろに「.名前」が続く。それ以外の名前はノートのプロパティ
                if ["file", "note", "formula"].contains(name), peek() == .symbol(".") || peek() == .symbol("[") {
                    return .property(name)
                }
                if peek() == .symbol("(") { throw BaseError("対応していない関数: \(name)()") }
                return .property("note." + name)
            case .symbol(let symbol):
                throw BaseError("ここに「\(symbol)」は書けません")
            }
        }
    }
}

private extension BaseValue {
    var isList: Bool { if case .list = self { true } else { false } }
}
