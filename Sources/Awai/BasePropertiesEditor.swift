import AppKit

/// 表の右上の「プロパティ」ボタンと、表に出す列をチェックボックスで選ぶポップオーバー（Obsidian の表ビューの Properties に倣う）
@MainActor
final class BasePropertiesEditor: NSObject, NSPopoverDelegate, NSSearchFieldDelegate {
    struct Candidate {
        /// 列の ID（`note.ステータス`）
        let property: String
        let title: String
    }

    let button = NSButton()
    /// 表示する列を変えたとき（列の ID を表示順に並べたもの）。`.base` への書き込みは呼び出し側が受け持つ
    var onChange: (([String]) -> Void)?

    private var visible: [String] = []
    private var candidates: [Candidate] = []
    private var popover: NSPopover?
    private let search = NSSearchField()
    private let list = NSStackView()
    private let scrollView = NSScrollView()
    private var scrollHeight: NSLayoutConstraint?

    override init() {
        super.init()
        button.isBordered = false
        button.refusesFirstResponder = true
        button.imagePosition = .imageLeading
        button.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        button.contentTintColor = .secondaryLabelColor
        button.attributedTitle = NSAttributedString(string: "プロパティ", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        button.toolTip = "表示するプロパティ"
        button.target = self
        button.action = #selector(togglePopover(_:))
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        search.placeholderString = "プロパティを検索"
        search.controlSize = .small
        search.font = .systemFont(ofSize: 12)
        search.delegate = self
    }

    /// ビューを切り替えたときや `.base` を読み直したとき。`visible` は今の列、`candidates` は選べるプロパティ（今の列を含む）
    func update(visible: [String], candidates: [Candidate]) {
        self.visible = visible
        // 表示名が重なるもの（`file.name` と `note.name` がどちらも「名前」など）は、`.base` での名前を添えて見分ける
        let titles = Dictionary(grouping: candidates, by: \.title)
        self.candidates = candidates.map { candidate in
            guard titles[candidate.title, default: []].count > 1 else { return candidate }
            let name = candidate.property.hasPrefix("note.") ? String(candidate.property.dropFirst(5)) : candidate.property
            return Candidate(property: candidate.property, title: "\(candidate.title)（\(name)）")
        }
        if popover?.isShown == true { rebuildList() }
    }

    // MARK: - ポップオーバー

    @objc private func togglePopover(_ sender: NSButton) {
        if let popover, popover.isShown { return popover.performClose(nil) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let controller = NSViewController()
        let container = NSView()
        let document = FlippedView()
        list.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        search.stringValue = ""
        for view in [search, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        let height = scrollView.heightAnchor.constraint(equalToConstant: 100)
        scrollHeight = height
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            height,
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        controller.view = container
        popover.contentViewController = controller
        self.popover = popover
        rebuildList()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        container.window?.makeFirstResponder(search)
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }

    func controlTextDidChange(_ notification: Notification) {
        rebuildList()
    }

    /// 表示中の列（表の順）を上に、ほかの候補をその下に並べる
    private func rebuildList() {
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        let byID = Dictionary(candidates.map { ($0.property, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = visible.map { byID[$0] ?? Candidate(property: $0, title: $0) }
        let hidden = candidates.filter { !visible.contains($0.property) }
        func matches(_ candidate: Candidate) -> Bool {
            query.isEmpty || candidate.title.localizedCaseInsensitiveContains(query)
                || candidate.property.localizedCaseInsensitiveContains(query)
        }
        for (candidates, isOn) in [(shown, true), (hidden, false)] {
            let matched = candidates.filter(matches)
            if !isOn, !matched.isEmpty, !list.arrangedSubviews.isEmpty {
                let separator = NSBox()
                separator.boxType = .separator
                list.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalToConstant: 220).isActive = true
            }
            for candidate in matched {
                let checkbox = NSButton(checkboxWithTitle: candidate.title, target: self, action: #selector(toggle(_:)))
                checkbox.font = .systemFont(ofSize: 12)
                checkbox.state = isOn ? .on : .off
                checkbox.identifier = NSUserInterfaceItemIdentifier(candidate.property)
                // 列は1つ以上残す
                checkbox.isEnabled = !(isOn && visible.count <= 1)
                checkbox.toolTip = candidate.property
                list.addArrangedSubview(checkbox)
            }
        }
        if list.arrangedSubviews.isEmpty {
            let empty = NSTextField(labelWithString: "該当するプロパティはありません")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            list.addArrangedSubview(empty)
        }
        list.layoutSubtreeIfNeeded()
        let size = list.fittingSize
        scrollHeight?.constant = min(360, size.height)
        popover?.contentSize = NSSize(width: max(240, size.width + 20), height: min(360, size.height) + 20 + 8 + search.fittingSize.height)
    }

    @objc private func toggle(_ sender: NSButton) {
        guard let property = sender.identifier?.rawValue else { return }
        var visible = visible.filter { $0 != property }
        if sender.state == .on { visible.append(property) }
        guard !visible.isEmpty else { return rebuildList() }
        self.visible = visible
        rebuildList()
        onChange?(visible)
    }
}

/// 上から並べるスクロールの中身
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
