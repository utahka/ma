import Foundation
import Yams

// MARK: - プロパティの削除

extension BaseFile {
    /// `.base` から `property`（列の ID、`note.ステータス` など）の定義と参照を消した YAML を返す。
    /// 消すのは `properties:` のその項目（`displayName`・`ma:` を含むブロック全体）と、全ビューの
    /// `order`・`columnSize`・`sort`・`groupBy` の参照。フィルタの式は壊さないように触らない（`filterUses` で知らせる）。
    /// ノートの値には触れない。
    /// ほかの書き戻しと同じく、該当する行だけを消す。消したあとの YAML を読み直し、元の YAML から同じものを
    /// 取り除いた内容と一致しなければ（形が想定と違えば）nil
    static func removingProperty(_ yaml: String, property id: String) -> String? {
        var lines = yaml.components(separatedBy: "\n")
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
        func matches(_ name: Substring) -> Bool { BaseExpression.propertyID(unquoted(name)) == id }
        /// `キー:` か `キー: 値` の行のキー
        func key(of line: String) -> Substring? {
            let text = line.drop { $0 == " " }
            if let colon = text.range(of: ": ") { return text[..<colon.lowerBound] }
            return text.hasSuffix(":") ? text.dropLast() : nil
        }
        /// `from` の次の行から、字下げが `depth` 以下の行（空行は除く）の手前まで。末尾の空行は含めない
        func end(after from: Int, depth: Int, limit: Int) -> Int {
            var last = from + 1
            while last < limit, isBlank(lines[last]) || indent(lines[last]) > depth { last += 1 }
            while last > from + 1, isBlank(lines[last - 1]) { last -= 1 }
            return last
        }

        // ビュー（後ろの行から消すので、先に消す）
        if let viewsLine = lines.firstIndex(of: "views:") {
            var items: [Int] = []
            var itemIndent: Int?
            var viewsEnd = lines.count
            for number in (viewsLine + 1)..<lines.count {
                let line = lines[number]
                if isBlank(line) { continue }
                let depth = indent(line)
                if depth == 0 { viewsEnd = number; break }
                if line.dropFirst(depth).hasPrefix("- ") {
                    if itemIndent == nil { itemIndent = depth }
                    if depth == itemIndent { items.append(number) }
                }
            }
            if let itemIndent {
                let keyIndent = itemIndent + 2
                for (position, start) in items.enumerated().reversed() {
                    var itemEnd = position + 1 < items.count ? items[position + 1] : viewsEnd
                    /// 項目の中の行を消す。項目の終わりも合わせて前へずらす
                    func delete(_ range: Range<Int>) {
                        lines.removeSubrange(range)
                        itemEnd -= range.count
                    }
                    /// キーの行から、そのキーの値の最後の行まで。項目の先頭の行（`- type: table`）のキーは対象にしない
                    func block(_ name: String) -> Range<Int>? {
                        guard let keyLine = ((start + 1)..<itemEnd).first(where: { number in
                            indent(lines[number]) == keyIndent && key(of: lines[number]) == Substring(name)
                        }) else { return nil }
                        var last = keyLine + 1
                        while last < itemEnd, isBlank(lines[last]) || indent(lines[last]) > keyIndent
                            || (indent(lines[last]) == keyIndent && lines[last].dropFirst(keyIndent).hasPrefix("- ")) {
                            last += 1
                        }
                        while last > keyLine + 1, isBlank(lines[last - 1]) { last -= 1 }
                        return keyLine..<last
                    }
                    /// ブロックの中身（キーの行より後ろ）を、リストの項目か子のキーごとに分ける
                    func entries(_ range: Range<Int>) -> [Range<Int>] {
                        let body = (range.lowerBound + 1)..<range.upperBound
                        guard let first = body.first(where: { !isBlank(lines[$0]) }) else { return [] }
                        let depth = indent(lines[first])
                        let starts = body.filter { !isBlank(lines[$0]) && indent(lines[$0]) == depth }
                        return starts.enumerated().map { index, from in
                            from..<(index + 1 < starts.count ? starts[index + 1] : range.upperBound)
                        }
                    }
                    /// 条件に合う項目を消し、1つも残らなければキーごと消す（後ろのキーから順に呼ぶ）
                    func remove(_ name: String, where hit: (Range<Int>) -> Bool) {
                        guard let range = block(name) else { return }
                        let all = entries(range)
                        let hits = all.filter(hit)
                        if !hits.isEmpty, hits.count == all.count {
                            delete(range)
                        } else {
                            for entry in hits.reversed() { delete(entry) }
                        }
                    }
                    /// `- 名前` の名前
                    func listItem(_ number: Int) -> Substring? {
                        let text = lines[number].drop { $0 == " " }
                        return text.hasPrefix("- ") ? text.dropFirst(2) : nil
                    }
                    /// `- property: 名前` か、項目の中の `property: 名前` の名前
                    func propertyValue(_ entry: Range<Int>) -> Substring? {
                        for number in entry {
                            var text = lines[number].drop { $0 == " " }
                            if text.hasPrefix("- ") { text = text.dropFirst(2) }
                            if text.hasPrefix("property: ") { return text.dropFirst("property: ".count) }
                        }
                        return nil
                    }

                    let keys = ["order", "columnSize", "sort", "groupBy"]
                        .compactMap { name in block(name).map { (name, $0.lowerBound) } }
                        .sorted { $0.1 > $1.1 }
                    for (name, _) in keys {
                        switch name {
                        case "order":
                            remove(name) { entry in listItem(entry.lowerBound).map(matches) == true }
                        case "columnSize":
                            remove(name) { entry in key(of: lines[entry.lowerBound]).map(matches) == true }
                        case "sort":
                            remove(name) { entry in propertyValue(entry).map(matches) == true }
                        default:
                            if let range = block(name), let value = propertyValue(range), matches(value) {
                                delete(range)
                            }
                        }
                    }
                }
            }
        }

        // `properties:` の項目
        if let propertiesLine = lines.firstIndex(where: { $0 == "properties:" || $0 == "properties: " }) {
            let blockEnd = end(after: propertiesLine, depth: 0, limit: lines.count)
            let children = ((propertiesLine + 1)..<blockEnd).filter { !isBlank(lines[$0]) }
            if let first = children.first {
                let depth = indent(lines[first])
                let starts = children.filter { indent(lines[$0]) == depth }
                let hits = starts.filter { key(of: lines[$0]).map(matches) == true }
                if !hits.isEmpty, hits.count == starts.count {
                    lines.removeSubrange(propertiesLine..<blockEnd)
                } else {
                    for start in hits.reversed() {
                        lines.removeSubrange(start..<end(after: start, depth: depth, limit: blockEnd))
                    }
                }
            }
        }

        let updated = lines.joined(separator: "\n")
        // 消したあとの中身が、元の中身から同じものを取り除いたものと一致するか確かめる
        guard let before = (try? Yams.load(yaml: yaml)) as? [String: Any],
              let after = (try? Yams.load(yaml: updated)) as? [String: Any],
              NSDictionary(dictionary: removing(id, from: before)).isEqual(to: after)
        else { return nil }
        return updated
    }

    /// `removingProperty` で消すものを、読み込んだ YAML の中身から取り除く（書き換えの確かめに使う）
    private static func removing(_ id: String, from root: [String: Any]) -> [String: Any] {
        func matches(_ name: Any) -> Bool { BaseExpression.propertyID("\(name)") == id }
        var root = root
        if var properties = root["properties"] as? [String: Any] {
            for key in properties.keys where matches(key) { properties[key] = nil }
            root["properties"] = properties.isEmpty ? nil : properties
        }
        if let views = root["views"] as? [[String: Any]] {
            root["views"] = views.map { view in
                var view = view
                if let order = view["order"] as? [Any] {
                    let kept = order.filter { !matches($0) }
                    view["order"] = kept.isEmpty ? nil : kept
                }
                if var sizes = view["columnSize"] as? [String: Any] {
                    for key in sizes.keys where matches(key) { sizes[key] = nil }
                    view["columnSize"] = sizes.isEmpty ? nil : sizes
                }
                if let sort = view["sort"] as? [[String: Any]] {
                    let kept = sort.filter { $0["property"].map(matches) != true }
                    view["sort"] = kept.isEmpty ? nil : kept
                }
                if let groupBy = view["groupBy"] as? [String: Any], groupBy["property"].map(matches) == true {
                    view["groupBy"] = nil
                }
                return view
            }
        }
        return root
    }

    private static func unquoted(_ text: Substring) -> String {
        let name = text.trimmingCharacters(in: .whitespaces)
        if name.count >= 2, let first = name.first, first == name.last, first == "\"" || first == "'" {
            return String(name.dropFirst().dropLast())
        }
        return name
    }

    /// `property` を使っているフィルタの場所（「全体」かビューの名前）。削除の確認で知らせる
    func filterUses(of property: String) -> [String] {
        var uses: [String] = []
        if filter?.properties.contains(property) == true { uses.append("全体") }
        for view in views where view.filter?.properties.contains(property) == true { uses.append(view.name) }
        return uses
    }
}

extension BaseFile.Filter {
    /// 式の中で使っているプロパティの ID
    var properties: Set<String> {
        switch self {
        case .expression(let expression): expression.properties
        case .and(let filters), .or(let filters), .not(let filters): filters.reduce(into: []) { $0.formUnion($1.properties) }
        }
    }
}

extension BaseExpression {
    /// 式の中で使っているプロパティの ID。`file.hasProperty("名前")` の名前も含める
    var properties: Set<String> {
        switch self {
        case .literal: return []
        case .property(let id): return [id]
        case .not(let expression): return expression.properties
        case .binary(_, let left, let right): return left.properties.union(right.properties)
        case .method(let receiver, _, let arguments):
            return arguments.reduce(receiver.properties) { $0.union($1.properties) }
        case .fileFunction(let name, let arguments):
            var ids = arguments.reduce(into: Set<String>()) { $0.formUnion($1.properties) }
            if name == "hasProperty" {
                for case .literal(.string(let key)) in arguments { ids.insert("note." + key) }
            }
            return ids
        }
    }
}
