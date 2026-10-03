import AppKit

/// `.base` の表の「＋」から出すポップオーバー。新しいプロパティの名前と型を選ぶ
final class BasePropertyAdder: NSViewController, NSTextFieldDelegate {
    /// 選べる型。Obsidian の型は `.obsidian/types.json` に、Awai の型は `.base` の `ma:` に書く
    enum Kind: CaseIterable {
        case text, number, date, checkbox, select, multiSelect, status

        var label: String {
            switch self {
            case .text: "テキスト"
            case .number: "数値"
            case .date: "日付"
            case .checkbox: "チェックボックス"
            case .select: "セレクト"
            case .multiSelect: "マルチセレクト"
            case .status: "ステータス"
            }
        }

        var symbolName: String {
            switch self {
            case .select: "chevron.down.circle"
            case .multiSelect: "list.bullet"
            case .status: "circle.dashed"
            default: (obsidianType ?? .text).symbolName
            }
        }

        /// `.obsidian/types.json` に書く型。テキストは既定なので書かない
        var obsidianType: PropertyType? {
            switch self {
            case .number: .number
            case .date: .date
            case .checkbox: .checkbox
            // マルチセレクトの値はリストなので、Obsidian でもリストとして見せる
            case .multiSelect: .multitext
            case .text, .select, .status: nil
            }
        }

        var schemaKind: PropertySchema.Kind? {
            switch self {
            case .select: .select
            case .multiSelect: .multiSelect
            case .status: .status
            default: nil
            }
        }
    }

    /// 追加を押したとき（名前は前後の空白を除いてある）
    var onAdd: ((String, Kind) -> Void)?
    /// 既存のプロパティの名前なら、その表示名を返す（型は選ばせず、列に足すだけにする）
    var existing: (String) -> String? = { _ in nil }

    private let nameField = NSTextField()
    private let typePopUp = NSPopUpButton()
    private let hintLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "追加", target: nil, action: nil)

    override func loadView() {
        nameField.placeholderString = "プロパティ名"
        nameField.delegate = self
        for kind in Kind.allCases {
            typePopUp.addItem(withTitle: kind.label)
            typePopUp.lastItem?.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
        }
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.isHidden = true
        addButton.bezelStyle = .push
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(add)
        addButton.isEnabled = false

        let typeLabel = NSTextField(labelWithString: "型")
        typeLabel.textColor = .secondaryLabelColor
        let typeRow = NSStackView(views: [typeLabel, typePopUp])
        typeRow.spacing = 8
        let buttonRow = NSStackView()
        buttonRow.setViews([addButton], in: .trailing)
        let stack = NSStackView(views: [nameField, typeRow, hintLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: hintLabel)
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalToConstant: 220),
            typePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            buttonRow.widthAnchor.constraint(equalTo: nameField.widthAnchor),
        ])
        // 中身の大きさでポップオーバーの大きさが決まるよう、四辺を余白つきで固定する
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    private var name: String { nameField.stringValue.trimmingCharacters(in: .whitespaces) }

    func controlTextDidChange(_ notification: Notification) {
        addButton.isEnabled = !name.isEmpty
        if !name.isEmpty, let title = existing(name) {
            hintLabel.stringValue = "既存のプロパティ「\(title)」を列に出します"
            hintLabel.isHidden = false
            typePopUp.isEnabled = false
        } else {
            hintLabel.isHidden = true
            typePopUp.isEnabled = true
        }
    }

    @objc private func add() {
        guard !name.isEmpty else { return }
        onAdd?(name, Kind.allCases[max(0, typePopUp.indexOfSelectedItem)])
    }
}
