import Foundation

/// `.base` の `properties` の `ma:` に書く、Awai 独自のプロパティの型。
/// キー名 `ma:` は旧名 Ma のときに書いたファイルを読めるよう、改名後もそのまま使う
/// ノートに書く値は Obsidian でも読める文字列・リストのままで、選択肢・色・既定値は Awai だけが使う
struct PropertySchema: Equatable {
    enum Kind: String {
        case select
        case multiSelect = "multi-select"
        case status
    }

    struct Option: Equatable {
        /// ファイルに書く文字列（例: `1 🔵 未着手`）
        let value: String
        /// Awai に表示する名前（例: `未着手`）
        let label: String
        /// 色の名前（gray / brown / orange / yellow / green / blue / purple / pink / red）
        let color: String
        /// status の区分（todo / doing / done）
        let group: String?
    }

    let kind: Kind
    let options: [Option]
    /// 値がないノートで、入っているものとして扱う値
    let defaultValue: String?

    /// `ma:` の辞書から作る。Awai の型でなければ nil
    init?(_ map: [String: Any]) {
        guard let kind = (map["type"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        self.kind = kind
        options = (map["options"] as? [Any] ?? []).compactMap { item in
            if let map = item as? [String: Any], let value = map["value"].map({ "\($0)" }) {
                return Option(
                    value: value,
                    label: (map["label"] as? String) ?? Self.label(from: value),
                    color: (map["color"] as? String) ?? Self.color(from: value),
                    group: map["group"] as? String
                )
            }
            guard !(item is [String: Any]) else { return nil }
            let value = "\(item)"
            return Option(value: value, label: Self.label(from: value), color: Self.color(from: value), group: nil)
        }
        let explicit = map["default"].map { "\($0)" }
        // status は空欄が不自然なので、既定値がなければ最初の todo（なければ最初の選択肢）にする
        defaultValue = explicit ?? (kind == .status ? (options.first { $0.group == "todo" } ?? options.first)?.value : nil)
    }

    func option(for value: String) -> Option? { options.first { $0.value == value } }

    /// 並び順。選択肢にない値は選択肢の後ろ
    func rank(of value: String) -> Int { options.firstIndex { $0.value == value } ?? options.count }

    // MARK: - 値から表示名と色を決める

    /// 先頭の番号と絵文字を外す（`3 🟣 完了` → `完了`）
    static func label(from value: String) -> String {
        var rest = Substring(value)
        rest = rest.drop { $0.isASCII && $0.isNumber }.drop { $0 == " " }
        let withoutEmoji = rest.drop { isEmoji($0) }.drop { $0 == " " }
        let label = withoutEmoji.count < rest.count ? withoutEmoji : rest
        return label.isEmpty ? value : String(label)
    }

    /// 値の中の色付きの丸や四角の絵文字から色を決める。なければ灰色
    static func color(from value: String) -> String {
        let table: [(String, String)] = [
            ("🔴", "red"), ("🟥", "red"), ("🟠", "orange"), ("🟧", "orange"), ("🟡", "yellow"), ("🟨", "yellow"),
            ("🟢", "green"), ("🟩", "green"), ("🔵", "blue"), ("🟦", "blue"), ("🟣", "purple"), ("🟪", "purple"),
            ("🟤", "brown"), ("🟫", "brown"),
        ]
        return table.first { value.contains($0.0) }?.1 ?? "gray"
    }

    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            || (character.unicodeScalars.first.map { $0.properties.isEmoji && $0.value > 0x238C } ?? false)
    }
}
