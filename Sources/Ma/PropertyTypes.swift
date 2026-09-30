import Foundation

/// Obsidian のプロパティの型（`.obsidian/types.json` の値）
enum PropertyType: String, CaseIterable {
    case text, multitext, number, checkbox, date, datetime, tags, aliases

    var isList: Bool { [.multitext, .tags, .aliases].contains(self) }

    var label: String {
        switch self {
        case .text: "テキスト"
        case .multitext: "リスト"
        case .number: "数値"
        case .checkbox: "チェックボックス"
        case .date: "日付"
        case .datetime: "日時"
        case .tags: "タグ"
        case .aliases: "別名"
        }
    }

    var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .multitext: "list.bullet"
        case .number: "number"
        case .checkbox: "checkmark.square"
        case .date: "calendar"
        case .datetime: "clock"
        case .tags: "tag"
        case .aliases: "arrowshape.turn.up.forward"
        }
    }

    /// 選べる型。tags と aliases は Obsidian が決まったキーにだけ使う
    static let choosable: [PropertyType] = [.text, .multitext, .number, .checkbox, .date, .datetime]
}

/// vault 全体のプロパティの型。Obsidian と同じ `.obsidian/types.json` を読み書きする
@MainActor
final class PropertyTypes {
    private let url: URL
    private var types: [String: PropertyType] = [:]

    init(root: URL) {
        url = root.appendingPathComponent(".obsidian/types.json")
        reload()
    }

    /// `types.json` に書かれている型（推測した型は含まない）
    var recorded: [String: PropertyType] { types }

    func reload() {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = json["types"] as? [String: String]
        else { types = [:]; return }
        types = map.compactMapValues(PropertyType.init(rawValue:))
    }

    /// 型が決まっていないキーは、値の形から推測する
    func type(of key: String, value: PropertyValue? = nil) -> PropertyType {
        if let type = types[key] { return type }
        switch key {
        case "tags": return .tags
        case "aliases": return .aliases
        default: break
        }
        switch value {
        case .list?: return .multitext
        case .scalar(let text)? where ["true", "false"].contains(text): return .checkbox
        default: return .text
        }
    }

    /// 型を記録する。Obsidian が書く形（2字下げ・並びは既存のまま）を崩さないよう、該当する行だけを書き換える
    func set(_ type: PropertyType, for key: String) {
        guard types[key] != type else { return }
        types[key] = type
        let entry = "\(Self.json(key)): \(Self.json(type.rawValue))"
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let pattern = "\"" + NSRegularExpression.escapedPattern(for: Self.escaped(key)) + "\"\\s*:\\s*\"[^\"]*\""
        if let range = text.range(of: pattern, options: .regularExpression) {
            text.replaceSubrange(range, with: entry)
        } else if let close = text.range(of: #"\}\s*\}\s*$"#, options: .regularExpression),
                  let last = text[..<close.lowerBound].lastIndex(where: { !$0.isWhitespace }) {
            // "types" の最後の要素の後ろに足す
            let hasItems = text[last] != "{"
            text.insert(contentsOf: (hasItems ? "," : "") + "\n    " + entry, at: text.index(after: last))
        } else {
            text = "{\n  \"types\": {\n    \(entry)\n  }\n}"
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("プロパティの型の保存に失敗: \(url.path): \(error)")
        }
    }

    private static func escaped(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func json(_ string: String) -> String { "\"" + escaped(string) + "\"" }
}
