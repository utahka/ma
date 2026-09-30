import Foundation
import Yams

/// vault のノート1つ分。`.base` の絞り込みと表に使う
struct NoteRecord: Sendable {
    let url: URL
    /// vault からの相対パス（拡張子を含む）
    let path: String
    let properties: [String: PropertyValue]
    let created: Date
    let modified: Date
    let size: Int

    var basename: String { url.deletingPathExtension().lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }

    /// vault の .md をすべて読む。重いので main スレッドの外で呼ぶ
    static func load(_ urls: [URL], root: URL) -> [NoteRecord] {
        urls.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            var properties: [String: PropertyValue] = [:]
            for entry in Frontmatter.parse(text)?.entries ?? [] { properties[entry.key] = entry.value }
            return NoteRecord(
                url: url, path: String(url.path.dropFirst(root.path.count + 1)), properties: properties,
                created: attributes?[.creationDate] as? Date ?? .distantPast,
                modified: attributes?[.modificationDate] as? Date ?? .distantPast,
                size: attributes?[.size] as? Int ?? 0
            )
        }
    }
}

/// `.base` ファイル（Obsidian の Bases）。表示に要る部分だけを読む
struct BaseFile {
    struct Sort {
        let property: String
        let ascending: Bool
    }

    struct View {
        let type: String
        let name: String
        let filter: Filter?
        let order: [String]
        /// `.base` に書かれたままの列名（`ステータス` など）。列の順番を書き戻すときに元の書き方を残す
        let rawOrder: [String]
        let sort: [Sort]
        let groupBy: Sort?
        let columnSize: [String: CGFloat]
        let limit: Int?
    }

    /// `and` / `or` / `not` の入れ子と、式の文字列
    indirect enum Filter {
        case expression(BaseExpression)
        case and([Filter])
        case or([Filter])
        case not([Filter])

        func matches(_ context: BaseContext) throws -> Bool {
            switch self {
            case .expression(let expression): try expression.evaluate(context).isTruthy
            case .and(let filters): try filters.allSatisfy { try $0.matches(context) }
            case .or(let filters): try filters.contains { try $0.matches(context) }
            case .not(let filters): try !filters.contains { try $0.matches(context) }
            }
        }
    }

    let filter: Filter?
    let displayNames: [String: String]
    /// `ma:` に書いた型。キーは列の ID（`note.ステータス`）
    let schemas: [String: PropertySchema]
    let views: [View]

    init(yaml: String) throws {
        let root: [String: Any]
        do {
            root = try Yams.load(yaml: yaml) as? [String: Any] ?? [:]
        } catch {
            throw BaseError("YAML を読めません: \(error)")
        }
        filter = try root["filters"].map(Self.filter)
        var names: [String: String] = [:]
        var schemas: [String: PropertySchema] = [:]
        for (key, value) in root["properties"] as? [String: Any] ?? [:] {
            let id = BaseExpression.propertyID(key)
            let map = value as? [String: Any]
            if let name = map?["displayName"] as? String { names[id] = name }
            if let ma = map?["ma"] as? [String: Any], let schema = PropertySchema(ma) { schemas[id] = schema }
        }
        displayNames = names
        self.schemas = schemas
        views = try (root["views"] as? [[String: Any]] ?? []).enumerated().map { index, view in
            try View(
                type: view["type"] as? String ?? "table",
                name: view["name"] as? String ?? "ビュー \(index + 1)",
                filter: view["filters"].map(Self.filter),
                order: (view["order"] as? [Any] ?? []).map { BaseExpression.propertyID("\($0)") },
                rawOrder: (view["order"] as? [Any] ?? []).map { "\($0)" },
                sort: (view["sort"] as? [[String: Any]] ?? []).compactMap(Self.sort),
                groupBy: (view["groupBy"] as? [String: Any]).flatMap(Self.sort),
                columnSize: (view["columnSize"] as? [String: Any] ?? [:]).reduce(into: [:]) { sizes, item in
                    if let width = (item.value as? NSNumber)?.doubleValue ?? Double("\(item.value)") {
                        sizes[BaseExpression.propertyID(item.key)] = CGFloat(width)
                    }
                },
                limit: view["limit"] as? Int
            )
        }
    }

    private static func sort(_ item: [String: Any]) -> Sort? {
        guard let property = item["property"] else { return nil }
        let direction = (item["direction"] as? String ?? "ASC").uppercased()
        return Sort(property: BaseExpression.propertyID("\(property)"), ascending: direction != "DESC")
    }

    private static func filter(_ node: Any) throws -> Filter {
        if let text = node as? String { return .expression(try BaseExpression.parse(text)) }
        if let map = node as? [String: Any], map.count == 1, let (key, value) = map.first {
            let children = try (value as? [Any] ?? [value]).map(filter)
            switch key {
            case "and": return .and(children)
            case "or": return .or(children)
            case "not": return .not(children)
            default: break
            }
        }
        throw BaseError("フィルタを読めません: \(node)")
    }

    func displayName(of property: String) -> String {
        if let name = displayNames[property] { return name }
        switch property {
        case "file.name", "file.basename": return "名前"
        case "file.path": return "パス"
        case "file.folder": return "フォルダ"
        case "file.ctime": return "作成日時"
        case "file.mtime": return "更新日時"
        case "file.size": return "サイズ"
        default: return property.hasPrefix("note.") ? String(property.dropFirst(5)) : property
        }
    }

    // MARK: - ビューの中身

    struct Group {
        /// グループの値。groupBy がないときは nil
        let value: BaseValue?
        let notes: [NoteRecord]
    }

    /// ビューに出すノートを、絞り込み・並べ替え・グループ化して返す
    /// ノートがこの `.base` の対象か（プロパティ欄で `ma:` の型を使うかどうか）。
    /// 全体のフィルタがあればそれだけで決める。ビューのフィルタは「完了を除く」のような絞り込みを含むので、
    /// 全体のフィルタがないときだけ、どれかのビューに合えば対象とみなす
    func contains(_ note: NoteRecord, types: [String: PropertyType]) -> Bool {
        let context = NoteContext(note: note, types: types, schemas: schemas)
        if let filter { return (try? filter.matches(context)) == true }
        return views.isEmpty || views.contains { (try? $0.filter?.matches(context) ?? true) == true }
    }

    func evaluate(_ view: View, notes: [NoteRecord], types: [String: PropertyType]) throws -> [Group] {
        var matched: [(note: NoteRecord, context: NoteContext)] = []
        for note in notes {
            let context = NoteContext(note: note, types: types, schemas: schemas)
            if try filter?.matches(context) ?? true, try view.filter?.matches(context) ?? true {
                matched.append((note, context))
            }
        }
        // 空の値は並びの向きによらず後ろに回す。選択肢のあるプロパティは options の順に並べる
        func ordered(_ a: BaseValue, _ b: BaseValue, property: String, ascending: Bool) -> Bool? {
            switch (a.isEmpty, b.isEmpty) {
            case (true, true): return nil
            case (true, false): return false
            case (false, true): return true
            default:
                var order = BaseValue.compare(a, b)
                if let schema = schemas[property], !schema.options.isEmpty {
                    let (x, y) = (schema.rank(of: a.text), schema.rank(of: b.text))
                    if x != y { order = x < y ? .orderedAscending : .orderedDescending }
                }
                return order == .orderedSame ? nil : (order == .orderedAscending) == ascending
            }
        }
        matched.sort { a, b in
            for key in view.sort {
                if let result = ordered(a.context.value(of: key.property), b.context.value(of: key.property),
                                        property: key.property, ascending: key.ascending) {
                    return result
                }
            }
            return a.note.path.localizedStandardCompare(b.note.path) == .orderedAscending
        }
        if let limit = view.limit { matched = Array(matched.prefix(limit)) }

        guard let groupBy = view.groupBy else { return [Group(value: nil, notes: matched.map(\.note))] }
        var groups: [(value: BaseValue, notes: [NoteRecord])] = []
        for item in matched {
            let value = item.context.value(of: groupBy.property)
            if let index = groups.firstIndex(where: { BaseValue.equal($0.value, value) }) {
                groups[index].notes.append(item.note)
            } else {
                groups.append((value, [item.note]))
            }
        }
        groups.sort { ordered($0.value, $1.value, property: groupBy.property, ascending: groupBy.ascending) ?? false }
        return groups.map { Group(value: $0.value, notes: $0.notes) }
    }
}

/// 1つのノートについて式を評価する
struct NoteContext: BaseContext {
    let note: NoteRecord
    /// `.obsidian/types.json` の型。数値とチェックボックスを文字列でなく数・真偽値として扱うのに使う
    let types: [String: PropertyType]
    /// `ma:` の型。値のないノートでは既定値を返す
    var schemas: [String: PropertySchema] = [:]

    func value(of property: String) -> BaseValue {
        switch property {
        case "file.name": return .string(note.url.lastPathComponent)
        case "file.basename": return .string(note.basename)
        case "file.path": return .string(note.path)
        case "file.folder": return .string(note.folder)
        case "file.ext": return .string(note.url.pathExtension)
        case "file.ctime": return .date(note.created)
        case "file.mtime": return .date(note.modified)
        case "file.size": return .number(Double(note.size))
        default: break
        }
        guard property.hasPrefix("note.") else { return .null }
        let key = String(property.dropFirst(5))
        let value = noteValue(key)
        if value.isEmpty, let fallback = schemas[property]?.defaultValue { return .string(fallback) }
        return value
    }

    private func noteValue(_ key: String) -> BaseValue {
        switch note.properties[key] {
        case nil, .other?: return .null
        case .list(let items)?: return .list(items.map { .string($0) })
        case .scalar(let text)?:
            if text.isEmpty { return .null }
            switch types[key] {
            case .number?: return Double(text).map(BaseValue.number) ?? .string(text)
            case .checkbox?: return .bool(text == "true")
            default: return .string(text)
            }
        }
    }

    func fileFunction(_ name: String, _ arguments: [BaseValue]) throws -> BaseValue {
        switch name {
        case "hasTag":
            func tag(_ text: String) -> String { text.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            let tags: [String]
            switch note.properties["tags"] {
            case .list(let items)?: tags = items
            case .scalar(let text)? where !text.isEmpty: tags = [text]
            default: tags = []
            }
            let names = Set(tags.map(tag))
            return .bool(arguments.contains { names.contains(tag($0.text)) })
        case "inFolder":
            return .bool(arguments.contains { note.folder == $0.text || note.folder.hasPrefix($0.text + "/") })
        case "hasProperty":
            return .bool(arguments.contains { note.properties[$0.text] != nil })
        default:
            throw BaseError("対応していない関数: file.\(name)()")
        }
    }
}

// MARK: - ビューの列の書き戻し

extension BaseFile {
    /// `views` の `index` 番目のビューの `order` と `columnSize` を書き換えた YAML を返す。
    /// `columnSize` は変える列の幅（キーは列の ID）。書かれている幅は行の位置を変えずに値だけ差し替え、ない列は末尾に足す（表示していない列の幅も残す）。
    /// YAML 全体を書き直すとリストの字下げなどが Obsidian の書き方と変わり、保存のたびに差分が出るので、
    /// Obsidian が書く形（ブロック形式）を前提に、その2つのキーの行だけを差し替える。形が想定と違えば nil
    static func updatingColumns(_ yaml: String, view index: Int, order: [String], columnSize: [String: Int]) -> String? {
        var lines = yaml.components(separatedBy: "\n")
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

        guard let viewsLine = lines.firstIndex(of: "views:") else { return nil }
        // ビューの項目の先頭（`  - type: table` のような行）
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
        let pad = String(repeating: " ", count: keyIndent)

        /// キーの行から、そのキーの値の最後の行まで
        func block(_ key: String) -> Range<Int>? {
            guard let keyLine = (start..<itemEnd).first(where: { number in
                let line = lines[number]
                return number == start
                    ? line.dropFirst(itemIndent + 2).hasPrefix(key + ":")
                    : indent(line) == keyIndent && line.dropFirst(keyIndent).hasPrefix(key + ":")
            }) else { return nil }
            guard keyLine != start else { return nil }
            var last = keyLine + 1
            while last < itemEnd, isBlank(lines[last]) || indent(lines[last]) > keyIndent
                || (indent(lines[last]) == keyIndent && lines[last].dropFirst(keyIndent).hasPrefix("- ")) {
                last += 1
            }
            return keyLine..<last
        }

        let orderLines = [pad + "order:"] + order.map { pad + "  - " + scalar($0) }
        let orderBlock = block("order")
        let sizeBlock = block("columnSize")
        var sizeLines: [String] = []
        var remaining = columnSize
        if let sizeBlock {
            sizeLines = Array(lines[sizeBlock])
            for number in sizeLines.indices.dropFirst() {
                let line = sizeLines[number]
                guard let colon = line.range(of: ": ", options: .backwards) else { continue }
                var key = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
                if key.count >= 2, key.hasPrefix("\""), key.hasSuffix("\"") { key = String(key.dropFirst().dropLast()) }
                let id = BaseExpression.propertyID(key)
                if let width = remaining.removeValue(forKey: id) {
                    sizeLines[number] = String(line[..<colon.upperBound]) + String(width)
                }
            }
        } else if !remaining.isEmpty {
            sizeLines = [pad + "columnSize:"]
        }
        // 新しい列の幅は、列の順番に並べて末尾に足す
        let newKeys = remaining.keys.sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }
        sizeLines += newKeys.map { pad + "  " + scalar($0) + ": " + String(remaining[$0]!) }
        // 後ろのブロックから差し替えると、前のブロックの行番号がずれない
        var replacements: [(Range<Int>, [String])] = []
        if let orderBlock { replacements.append((orderBlock, orderLines)) }
        if let sizeBlock { replacements.append((sizeBlock, sizeLines)) }
        var appended: [String] = []
        if orderBlock == nil { appended += orderLines }
        if sizeBlock == nil { appended += sizeLines }
        if !appended.isEmpty { replacements.append((itemEnd..<itemEnd, appended)) }
        for (range, replacement) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            lines.replaceSubrange(range, with: replacement)
        }
        return lines.joined(separator: "\n")
    }

    /// 引用符なしでは読み違える名前だけ囲む
    private static func scalar(_ text: String) -> String {
        let special = text.contains(": ") || text.contains(" #") || text.hasSuffix(":")
            || text.first.map { "-?:,[]{}#&*!|>'\"%@`".contains($0) } == true
            || text != text.trimmingCharacters(in: .whitespaces)
        guard special else { return text }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
