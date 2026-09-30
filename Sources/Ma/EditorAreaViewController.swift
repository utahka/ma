import AppKit

/// タブバーと、タブごとのエディタ。選択中のタブのエディタだけを表示し、ほかのタブのエディタは画面から外して取っておく
final class EditorAreaViewController: NSViewController, NSMenuItemValidation {
    let tabBar = TabBarView()
    var onChange: ((URL, String) -> Void)?
    var onOpenLink: ((LinkTarget, _ newTab: Bool) -> Void)?

    private let content = NSView()
    private var editors: [Tab.ID: EditorViewController] = [:]
    private weak var shown: EditorViewController?

    private static let sourceModeKey = "sourceMode"
    /// ソース表示（装飾なし）かどうか。⌘E で全タブまとめて切り替え、次回の起動にも引き継ぐ
    private var sourceMode = AppDefaults.shared.bool(forKey: sourceModeKey)

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
        view = container
    }

    func show(_ document: OpenDocument?, in tab: Tab.ID) {
        editor(for: tab).show(document)
    }

    /// タブの並びと選択に合わせて、タブバーと表示するエディタを揃える。閉じたタブのエディタは捨てる
    func update(tabs: [Tab], activeIndex: Int) {
        tabBar.titles = tabs.map(\.title)
        tabBar.selectedIndex = activeIndex
        let ids = Set(tabs.map(\.id))
        for (id, editor) in editors where !ids.contains(id) {
            editor.view.removeFromSuperview()
            editor.removeFromParent()
            editors[id] = nil
        }
        let active = editor(for: tabs[activeIndex].id)
        guard active !== shown else { return }
        shown?.view.removeFromSuperview()
        active.view.frame = content.bounds
        active.view.autoresizingMask = [.width, .height]
        content.addSubview(active.view)
        shown = active
        active.focus()
    }

    private func editor(for tab: Tab.ID) -> EditorViewController {
        if let editor = editors[tab] { return editor }
        let editor = EditorViewController()
        // 読み込み時に空の表示にするので、中身を渡す前に読み込んでおく
        editor.loadViewIfNeeded()
        editor.sourceMode = sourceMode
        editor.onChange = { [weak self] url, text in self?.onChange?(url, text) }
        editor.onOpenLink = { [weak self] target, newTab in self?.onOpenLink?(target, newTab) }
        addChild(editor)
        editors[tab] = editor
        return editor
    }

    @objc func toggleSourceMode(_ sender: Any?) {
        sourceMode.toggle()
        AppDefaults.shared.set(sourceMode, forKey: Self.sourceModeKey)
        for editor in editors.values { editor.sourceMode = sourceMode }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSourceMode(_:)) {
            menuItem.state = sourceMode ? .on : .off
        }
        return true
    }
}
