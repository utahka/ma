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
