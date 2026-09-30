import Foundation

/// Obsidian のブックマーク（`.obsidian/bookmarks.json`）の1項目
struct Bookmark {
    enum Kind {
        case file
        case folder
        case url
        case group([Bookmark])
        /// 検索・グラフなど Ma が扱わない種類。ファイルには残す
        case other
    }

    let kind: Kind
    let title: String?
    /// vault からの相対パス（file・folder のとき）
    let path: String?
    /// file・folder は vault 内の場所、url はその URL
    let url: URL?
    /// ブックマークの木の中の位置（外すときに使う）
    let indexPath: [Int]

    var displayName: String {
        if let title, !title.isEmpty { return title }
        switch kind {
        case .file:
            let name = (path.map { ($0 as NSString).lastPathComponent }) ?? ""
            return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
        case .folder: return path.map { ($0 as NSString).lastPathComponent } ?? ""
        case .url: return url?.absoluteString ?? ""
        case .group: return "グループ"
        case .other: return "（未対応のブックマーク）"
        }
    }
}

/// `.obsidian/bookmarks.json` の読み書き。Obsidian と同じファイルを使い、Ma が扱わない種類の項目やキーもそのまま残す
enum Bookmarks {
    static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(".obsidian/bookmarks.json")
    }

    /// ファイルがなければ空として扱う。読めない・壊れているときは nil（上書きして消さないように）
    static func readDocument(root: URL) -> (document: [String: Any], data: Data?)? {
        let url = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return (["items": []], nil) }
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (document, data)
    }

    static func write(_ document: [String: Any], root: URL) throws {
        let url = fileURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(serialize(document).utf8).write(to: url, options: .atomic)
    }

    static func parse(_ items: [Any], root: URL, prefix: [Int] = []) -> [Bookmark] {
        items.enumerated().compactMap { index, value in
            guard let item = value as? [String: Any] else { return nil }
            let indexPath = prefix + [index]
            let title = item["title"] as? String
            let path = item["path"] as? String
            switch item["type"] as? String {
            case "file", "folder":
                guard let path else { return nil }
                let isFolder = item["type"] as? String == "folder"
                return Bookmark(kind: isFolder ? .folder : .file, title: title, path: path,
                                url: root.appendingPathComponent(path, isDirectory: isFolder), indexPath: indexPath)
            case "url":
                return Bookmark(kind: .url, title: title, path: nil,
                                url: (item["url"] as? String).flatMap(URL.init(string:)), indexPath: indexPath)
            case "group":
                let children = parse(item["items"] as? [Any] ?? [], root: root, prefix: indexPath)
                return Bookmark(kind: .group(children), title: title, path: nil, url: nil, indexPath: indexPath)
            default:
                return Bookmark(kind: .other, title: title, path: nil, url: nil, indexPath: indexPath)
            }
        }
    }

    /// ファイル名は濁点が分解形（NFD）で返ってくることがあるので、合成形にそろえて比べる
    static func samePath(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping == b.precomposedStringWithCanonicalMapping
    }

    static func contains(path: String, in items: [Any]) -> Bool {
        items.contains { value in
            guard let item = value as? [String: Any] else { return false }
            if let children = item["items"] as? [Any] { return contains(path: path, in: children) }
            return ["file", "folder"].contains(item["type"] as? String) && (item["path"] as? String).map { samePath($0, path) } == true
        }
    }

    /// グループの中も含め、そのパスの file・folder の項目をすべて外す
    static func removing(path: String, from items: [Any]) -> [Any] {
        items.compactMap { value in
            guard var item = value as? [String: Any] else { return value }
            if let children = item["items"] as? [Any] {
                item["items"] = removing(path: path, from: children)
                return item
            }
            let matches = ["file", "folder"].contains(item["type"] as? String)
                && (item["path"] as? String).map { samePath($0, path) } == true
            return matches ? nil : item
        }
    }

    static func removing(at indexPath: [Int], from items: [Any]) -> [Any] {
        guard let first = indexPath.first, items.indices.contains(first) else { return items }
        var items = items
        if indexPath.count == 1 {
            items.remove(at: first)
        } else if var group = items[first] as? [String: Any] {
            group["items"] = removing(at: Array(indexPath.dropFirst()), from: group["items"] as? [Any] ?? [])
            items[first] = group
        }
        return items
    }

    /// Obsidian が書き出す形（JavaScript の `JSON.stringify(data, null, 2)`）に合わせる。
    /// キーの順番は Obsidian の並びに寄せ、git の差分が余計に出ないようにする
    static func serialize(_ value: Any, indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case let object as [String: Any]:
            guard !object.isEmpty else { return "{}" }
            let order = ["type", "ctime", "path", "subpath", "url", "query", "items", "title"]
            let keys = object.keys.sorted { a, b in
                let (ia, ib) = (order.firstIndex(of: a) ?? order.count, order.firstIndex(of: b) ?? order.count)
                return ia != ib ? ia < ib : a < b
            }
            let lines = keys.map { "\(inner)\(quote($0)): \(serialize(object[$0]!, indent: inner))" }
            return "{\n" + lines.joined(separator: ",\n") + "\n\(indent)}"
        case let array as [Any]:
            guard !array.isEmpty else { return "[]" }
            return "[\n" + array.map { inner + serialize($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case let string as String:
            return quote(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            if CFNumberIsFloatType(number), double != double.rounded() { return "\(double)" }
            return "\(number.int64Value)"
        default:
            return "null"
        }
    }

    private static func quote(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
