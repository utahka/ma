import AppKit
import XCTest
@testable import Awai

final class NoteRenameTests: XCTestCase {
    func testRenameUpdatesOpenTabHistoryBookmarkAndSaveDestination() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let old = root.appendingPathComponent("旧名.md")
            let other = root.appendingPathComponent("other.md")
            try "original".write(to: old, atomically: true, encoding: .utf8)
            try "other".write(to: other, atomically: true, encoding: .utf8)
            let vault = Vault()
            vault.setRoot(root, remember: false)
            vault.open(old)
            vault.toggleBookmark(old)
            vault.open(other)
            let historyID = vault.activeTab.id
            vault.open(old, newTab: true)
            let tabID = vault.activeTab.id
            let detached = Vault(sharingFolderWith: vault, tab: vault.detachTab(at: vault.activeIndex)!.tab, viewState: nil)
            let editor = EditorViewController()
            editor.loadViewIfNeeded()
            editor.show(OpenDocument(url: old, text: "edited"))
            detached.onDocumentRename = { from, to in editor.renameDocument(from: from, to: to) }
            detached.textDidChange("edited", url: old)
            let new = try detached.renameNote(old, to: "新しい名前")
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
            XCTAssertEqual(try String(contentsOf: new, encoding: .utf8), "edited")
            XCTAssertEqual(detached.activeTab.id, tabID)
            XCTAssertEqual(detached.activeTab.url, new)
            XCTAssertEqual(editor.url, new)
            XCTAssertEqual(vault.tabs.first { $0.id == historyID }?.back.last?.url, new)
            XCTAssertTrue(vault.isBookmarked(new))
            detached.textDidChange("next edit", url: editor.url!)
            detached.saveNow()
            XCTAssertEqual(try String(contentsOf: new, encoding: .utf8), "next edit")
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
            detached.leaveFolder()
            vault.leaveFolder()
        }
    }

    func testCollisionAndInvalidNamesLeaveFilesIntact() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let old = root.appendingPathComponent("old.md")
            let existing = root.appendingPathComponent("existing.md")
            try "original".write(to: old, atomically: true, encoding: .utf8)
            try "keep".write(to: existing, atomically: true, encoding: .utf8)
            let vault = Vault()
            vault.setRoot(root, remember: false)
            vault.open(old)
            for name in ["existing", "", "../escape", ".hidden", "a/b", "a\nname"] {
                XCTAssertThrowsError(try vault.renameNote(old, to: name))
            }
            XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "original")
            XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
            XCTAssertEqual(try vault.renameNote(old, to: "old"), old)
            vault.leaveFolder()
        }
    }
    func testPathDoubleClickAndMenuRequestRename() async {
        await MainActor.run {
            _ = NSApplication.shared
            let area = EditorAreaViewController()
            area.loadViewIfNeeded()
            area.setNotePath("folder/name.md")
            var requested = 0
            area.onRenameNote = { requested += 1 }
            let label = area.view.subviews.compactMap { $0 as? NSTextField }
                .first { $0.toolTip?.contains("ダブルクリック") == true }!
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil,
                                            eventNumber: 0, clickCount: 2, pressure: 1)!
            label.mouseDown(with: click)
            XCTAssertEqual(requested, 1)
            let menu = label.menu(for: click)!
            XCTAssertEqual(menu.items.map(\.title), ["ファイル名を変更…", "パスをコピー"])
            menu.performActionForItem(at: 0)
            XCTAssertEqual(requested, 2)
        }
    }

}
