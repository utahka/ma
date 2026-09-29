import Foundation

/// デイリーノートの置き場所と書式。vault の `.obsidian` にある Obsidian の設定
/// （コアのデイリーノートと Calendar プラグイン）を読み、なければ既定値を使う
struct DailyNoteSettings {
    var folder = ""
    /// moment.js 形式の日付書式（Obsidian と同じ）
    var format = "YYYY-MM-DD"
    /// vault からの相対パス（拡張子なし）
    var template = ""
    /// 1 が日曜、2 が月曜（Calendar.firstWeekday と同じ）
    var firstWeekday = Calendar.current.firstWeekday

    static func load(root: URL) -> DailyNoteSettings {
        var settings = DailyNoteSettings()
        let config = root.appending(path: ".obsidian")
        if let json = readJSON(config.appending(path: "daily-notes.json")) {
            if let folder = json["folder"] as? String { settings.folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            if let format = json["format"] as? String, !format.isEmpty { settings.format = format }
            if let template = json["template"] as? String { settings.template = template }
        }
        if let json = readJSON(config.appending(path: "plugins/calendar/data.json")) {
            switch json["weekStart"] as? String {
            case "sunday": settings.firstWeekday = 1
            case "monday": settings.firstWeekday = 2
            case "saturday": settings.firstWeekday = 7
            default: break
            }
        }
        return settings
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// vault のデイリーノートを日付から引く・作る
struct DailyNotes {
    let root: URL
    let settings: DailyNoteSettings
    private let formatter: DateFormatter

    init(root: URL) {
        self.root = root
        settings = .load(root: root)
        formatter = Self.makeFormatter(momentFormat: settings.format)
    }

    private var folderURL: URL {
        settings.folder.isEmpty ? root : root.appending(path: settings.folder, directoryHint: .isDirectory)
    }

    func url(for date: Date) -> URL {
        folderURL.appending(path: formatter.string(from: date) + ".md")
    }

    /// デイリーノートなら日付を返す
    func date(of url: URL) -> Date? {
        guard url.deletingLastPathComponent().standardizedFileURL.path == folderURL.standardizedFileURL.path,
              url.pathExtension.lowercased() == "md" else { return nil }
        return formatter.date(from: url.deletingPathExtension().lastPathComponent)
    }

    /// テンプレートを展開した新しいノートの本文。Templater の `<% %>` は実行できないので取り除く
    func initialText(for date: Date) -> String {
        guard !settings.template.isEmpty else { return "" }
        let path = settings.template.hasSuffix(".md") ? settings.template : settings.template + ".md"
        guard var text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { return "" }

        // タグだけの行は行ごと消す（表の途中に空行が残ると表が切れる）
        text = text.replacing(/^[ \t]*<%[\s\S]*?%>[ \t]*\n/.anchorsMatchLineEndings(), with: "")
        text = text.replacing(/<%[\s\S]*?%>/, with: "")

        let title = formatter.string(from: date)
        text = text.replacing(/\{\{\s*(date|time|title)\s*(?::([^}]*))?\}\}/) { match in
            let format = match.output.2.map(String.init)
            switch match.output.1 {
            case "title": return title
            case "time": return Self.makeFormatter(momentFormat: format ?? "HH:mm").string(from: Date())
            default: return format.map { Self.makeFormatter(momentFormat: $0).string(from: date) } ?? title
            }
        }
        return text
    }

    func exists(for date: Date) -> Bool {
        FileManager.default.fileExists(atPath: url(for: date).path)
    }

    /// moment.js の書式を DateFormatter の書式に変える。よく使う記号だけに対応する
    static func makeFormatter(momentFormat: String) -> DateFormatter {
        let tokens: [(String, String)] = [
            ("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
            ("DDDD", "DDD"), ("DD", "dd"), ("Do", "d"), ("D", "d"),
            ("dddd", "EEEE"), ("ddd", "EEE"), ("dd", "EEEEEE"), ("d", "e"),
            ("gggg", "YYYY"), ("GGGG", "YYYY"), ("ww", "ww"), ("w", "w"), ("WW", "ww"), ("W", "w"),
            ("HH", "HH"), ("H", "H"), ("hh", "hh"), ("h", "h"), ("mm", "mm"), ("m", "m"),
            ("ss", "ss"), ("s", "s"), ("A", "a"), ("a", "a"),
        ]
        var result = ""
        var rest = Substring(momentFormat)
        func quoted(_ s: some StringProtocol) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        while let first = rest.first {
            if first == "[", let close = rest.firstIndex(of: "]") {
                result += quoted(rest[rest.index(after: rest.startIndex)..<close])
                rest = rest[rest.index(after: close)...]
            } else if let (moment, icu) = tokens.first(where: { rest.hasPrefix($0.0) }) {
                result += icu
                rest = rest.dropFirst(moment.count)
            } else {
                result += first.isLetter || first == "'" ? quoted(String(first)) : String(first)
                rest = rest.dropFirst()
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = result
        return formatter
    }
}
