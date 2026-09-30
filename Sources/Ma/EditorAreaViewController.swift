import AppKit

/// タブバーと、タブごとの中身（ノートのエディタか `.base` の表）。選択中のタブの中身だけを表示し、ほかのタブの中身は画面から外して取っておく
final class EditorAreaViewController: NSViewController, NSMenuItemValidation {
    let tabBar = TabBarView()
    var onChange: ((URL, String) -> Void)?
    var onOpenLink: ((LinkTarget, _ newTab: Bool) -> Void)?
    var onOpenNote: ((URL, _ newTab: Bool) -> Void)?
    /// `.base` の表でプロパティの値を変えたとき
    var onSetProperty: ((URL, String, PropertyValue, PropertyType) -> Void)?
    /// `.base` の表でプロパティ名を変えたとき（対象のノート、古い名前、新しい名前）
    var onRenameProperty: (([URL], String, String) -> Void)?
    var propertyTypes: () -> PropertyTypes? = { nil }
    var loadNotes: () async -> [NoteRecord] = { [] }
    var propertySchemas: (_ url: URL, _ text: String) -> [String: PropertySchema] = { _, _ in [:] }
    /// 右上の☆で、開いているノートをお気に入りに加える・外す
    var onToggleFavorite: (() -> Void)?

    private let content = NSView()
    private var contents: [Tab.ID: NSViewController] = [:]
    private weak var shown: NSViewController?
    private let favoriteButton = NSButton()
    private let pathLabel = PassthroughLabel(labelWithString: "")

    private static let sourceModeKey = "sourceMode"
    /// ソース表示（装飾なし）かどうか。⌘E で全タブまとめて切り替え、次回の起動にも引き継ぐ
    private var sourceMode = AppDefaults.shared.bool(forKey: sourceModeKey)
    private static let hidesCalloutIconsKey = "hidesCalloutIcons"
    /// コールアウトのタイトルの左にアイコンを描くかどうか。表示メニューで全タブまとめて切り替え、次回の起動にも引き継ぐ
    private var showsCalloutIcons = !AppDefaults.shared.bool(forKey: hidesCalloutIconsKey)

    private var editors: [EditorViewController] { contents.values.compactMap { $0 as? EditorViewController } }
    private var bases: [BaseViewController] { contents.values.compactMap { $0 as? BaseViewController } }

    override func loadView() {
        let container = NSView()
        for view in [tabBar, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        favoriteButton.isBordered = false
        favoriteButton.refusesFirstResponder = true
        favoriteButton.target = self
        favoriteButton.action = #selector(favoriteClicked(_:))
        favoriteButton.translatesAutoresizingMaskIntoConstraints = false
        // 中身より後に載せて、スクロールする本文の上に重ねる
        container.addSubview(favoriteButton)
        NSLayoutConstraint.activate([
            favoriteButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            // 右端のスクローラーに重ならないよう少し内側に置く
            favoriteButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            favoriteButton.widthAnchor.constraint(equalToConstant: 26),
            favoriteButton.heightAnchor.constraint(equalToConstant: 26),
        ])
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(pathLabel)
        NSLayoutConstraint.activate([
            // ☆と縦の中心を揃え、左端も☆の右端と同じだけ内側に置く
            pathLabel.centerYAnchor.constraint(equalTo: favoriteButton.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: favoriteButton.leadingAnchor, constant: -12),
        ])
        setFavorite(nil)
        setNotePath(nil)
        view = container
    }

    /// ☆の表示を開いているノートに合わせる。nil はノートを開いていない（ボタンを隠す）
    func setFavorite(_ isFavorite: Bool?) {
        favoriteButton.isHidden = isFavorite == nil
        let filled = isFavorite == true
        let label = filled ? "お気に入りから外す" : "お気に入りに追加"
        favoriteButton.image = NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        favoriteButton.contentTintColor = filled ? .systemYellow : .secondaryLabelColor
        favoriteButton.toolTip = label
    }

    /// 左上に vault からの相対パスを出す（Obsidian のパンくずに近い見た目）。フォルダ部分は薄くし、拡張子は省く。nil で隠す
    func setNotePath(_ path: String?) {
        pathLabel.isHidden = path == nil
        guard let path else { return }
        let name = (path as NSString).lastPathComponent
        // 区切りの両脇を空けて読みやすくする（`Tasks / Tickets / ノート名`）
        let folder = String(path.dropLast(name.count)).split(separator: "/").map { $0 + " / " }.joined()
        let font = pathLabel.font ?? .systemFont(ofSize: 12)
        let text = NSMutableAttributedString(string: folder, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
        text.append(NSAttributedString(string: (name as NSString).deletingPathExtension,
                                       attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        pathLabel.attributedStringValue = text
        pathLabel.toolTip = path
    }

    @objc private func favoriteClicked(_ sender: NSButton) { onToggleFavorite?() }

    func show(_ document: OpenDocument?, in tab: Tab.ID) {
        if let document, document.url.pathExtension.lowercased() == "base" {
            content(for: tab, make: makeBase).show(document)
        } else {
            content(for: tab, make: makeEditor).show(document)
        }
    }

    func viewState(of tab: Tab.ID) -> NoteViewState? {
        (contents[tab] as? EditorViewController)?.viewState
    }

    /// タブの並びと選択に合わせて、タブバーと表示する中身を揃える。閉じたタブの中身は捨てる
    func update(tabs: [Tab], activeIndex: Int, canGoBack: Bool, canGoForward: Bool) {
        tabBar.titles = tabs.map(\.title)
        tabBar.selectedIndex = activeIndex
        tabBar.canGoBack = canGoBack
        tabBar.canGoForward = canGoForward
        let ids = Set(tabs.map(\.id))
        for (id, controller) in contents where !ids.contains(id) { discard(id, controller) }
        let active = contents[tabs[activeIndex].id] ?? content(for: tabs[activeIndex].id, make: makeEditor)
        guard active !== shown else { return }
        shown?.view.removeFromSuperview()
        active.view.frame = content.bounds
        active.view.autoresizingMask = [.width, .height]
        content.addSubview(active.view)
        shown = active
        if let editor = active as? EditorViewController { editor.focus() }
        if let base = active as? BaseViewController {
            // ほかのタブでノートを書き換えたかもしれないので、選ぶたびに読み直す
            base.reload()
            base.focus()
        }
    }

    /// タブで開いているノートなら、そのエディタでプロパティを書き換えて true を返す
    func setProperty(in url: URL, _ key: String, to value: PropertyValue, type: PropertyType) -> Bool {
        guard let editor = editors.first(where: { $0.url?.path == url.path }) else { return false }
        editor.setProperty(key, to: value, type: type)
        return true
    }

    /// タブで開いているノートなら、そのエディタでプロパティ名を変える。開いていなければ nil、書き換えなかったら false
    func renameProperty(in url: URL, from key: String, to newKey: String) -> Bool? {
        guard let editor = editors.first(where: { $0.url?.path == url.path }) else { return nil }
        return editor.renameProperty(key, to: newKey)
    }

    /// vault のファイルが変わったとき。開いている `.base` の表と、ノートのプロパティ欄の型を作り直す
    func notesDidChange() {
        for base in bases { base.reload() }
        for editor in editors { editor.refreshSchemas() }
    }

    /// タブの中身が求める種類でなければ作り直す（同じタブでノートから `.base` に移ったときなど）
    private func content<Controller: NSViewController>(for tab: Tab.ID, make: () -> Controller) -> Controller {
        if let controller = contents[tab] as? Controller { return controller }
        let controller = make()
        if let old = contents[tab] {
            let wasShown = old === shown
            discard(tab, old)
            if wasShown {
                controller.view.frame = content.bounds
                controller.view.autoresizingMask = [.width, .height]
                content.addSubview(controller.view)
                shown = controller
            }
        }
        addChild(controller)
        contents[tab] = controller
        return controller
    }

    private func discard(_ tab: Tab.ID, _ controller: NSViewController) {
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        contents[tab] = nil
    }

    private func makeEditor() -> EditorViewController {
        let editor = EditorViewController()
        // 読み込み時に空の表示にするので、中身を渡す前に読み込んでおく
        editor.loadViewIfNeeded()
        editor.sourceMode = sourceMode
        editor.showsCalloutIcons = showsCalloutIcons
        editor.onChange = { [weak self] url, text in self?.onChange?(url, text) }
        editor.onOpenLink = { [weak self] target, newTab in self?.onOpenLink?(target, newTab) }
        editor.propertyTypes = { [weak self] in self?.propertyTypes() }
        editor.propertySchemas = { [weak self] url, text in self?.propertySchemas(url, text) ?? [:] }
        return editor
    }

    private func makeBase() -> BaseViewController {
        let base = BaseViewController()
        base.loadViewIfNeeded()
        base.loadNotes = { [weak self] in await self?.loadNotes() ?? [] }
        base.propertyTypes = { [weak self] in self?.propertyTypes()?.recorded ?? [:] }
        base.onOpenNote = { [weak self] url, newTab in self?.onOpenNote?(url, newTab) }
        base.onSetProperty = { [weak self] url, key, value, type in self?.onSetProperty?(url, key, value, type) }
        base.onRenameProperty = { [weak self] urls, key, newKey in self?.onRenameProperty?(urls, key, newKey) }
        base.onSetPropertyType = { [weak self] key, type in self?.propertyTypes()?.set(type, for: key) }
        return base
    }

    @objc func toggleSourceMode(_ sender: Any?) {
        sourceMode.toggle()
        AppDefaults.shared.set(sourceMode, forKey: Self.sourceModeKey)
        for editor in editors { editor.sourceMode = sourceMode }
    }

    @objc func toggleCalloutIcons(_ sender: Any?) {
        showsCalloutIcons.toggle()
        AppDefaults.shared.set(!showsCalloutIcons, forKey: Self.hidesCalloutIconsKey)
        for editor in editors { editor.showsCalloutIcons = showsCalloutIcons }
    }

    @objc func addProperty(_ sender: Any?) { (shown as? EditorViewController)?.addProperty() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSourceMode(_:)) {
            menuItem.state = sourceMode ? .on : .off
        }
        if menuItem.action == #selector(toggleCalloutIcons(_:)) {
            menuItem.state = showsCalloutIcons ? .on : .off
        }
        if menuItem.action == #selector(addProperty(_:)) { return shown is EditorViewController }
        return true
    }
}

/// 本文の上に重ねる表示だけのラベル。クリックは下の本文に通す
private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
