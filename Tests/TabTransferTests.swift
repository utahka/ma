import AppKit
import XCTest
@testable import Awai

final class TabTransferTests: XCTestCase {
    func testTransferPreservesTabAndHistoryAndLastTab() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let first = root.appendingPathComponent("first.md")
            let second = root.appendingPathComponent("second.md")
            try "first".write(to: first, atomically: true, encoding: .utf8)
            try "second".write(to: second, atomically: true, encoding: .utf8)
            let source = Vault()
            source.setRoot(root, remember: false)
            source.open(first)
            source.open(second)
            let tab = source.activeTab
            let destination = Vault(sharingFolderWith: source, tab: Tab(), viewState: nil)
            source.textDidChange("edited", url: second)
            XCTAssertTrue(source.transferTab(at: 0, to: destination, at: 0, preservingContent: false))
            XCTAssertEqual(source.tabs.count, 1)
            XCTAssertNil(source.activeTab.url)
            XCTAssertEqual(destination.activeTab.id, tab.id)
            XCTAssertEqual(destination.activeTab.back.last?.url, first)
            XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "edited")
            XCTAssertTrue(destination.transferTab(at: 0, to: source, at: 1, preservingContent: false))
            XCTAssertEqual(source.activeTab.id, tab.id)
            XCTAssertFalse(source.transferTab(at: 1, to: Vault(), at: 0, preservingContent: false))
            source.leaveFolder()
            destination.leaveFolder()
        }
    }

    func testEditorAndUndoHistorySurviveTransfer() async {
        await MainActor.run {
            _ = NSApplication.shared
            let source = EditorAreaViewController()
            let destination = EditorAreaViewController()
            source.loadViewIfNeeded()
            destination.loadViewIfNeeded()
            let tab = Tab(url: URL(fileURLWithPath: "/tmp/transfer.md"))
            source.show(OpenDocument(url: tab.url!, text: "before"), in: tab.id)
            source.update(tabs: [tab], activeIndex: 0, canGoBack: false, canGoForward: false)
            let controller = source.children.first!
            @MainActor func findTextView(_ view: NSView) -> EditorTextView? {
                if let text = view as? EditorTextView { return text }
                return view.subviews.lazy.compactMap(findTextView).first
            }
            let text = findTextView(controller.view)!
            text.undoManager!.groupsByEvent = false
            text.undoManager!.beginUndoGrouping()
            text.replace(NSRange(location: 0, length: 6), with: "after", actionName: "Edit")
            text.undoManager?.endUndoGrouping()
            let undo = text.undoManager!
            XCTAssertTrue(undo.canUndo)
            let moved = source.takeContent(for: tab.id)!
            XCTAssertTrue(moved === controller)
            destination.adoptContent(moved, for: tab.id)
            destination.update(tabs: [tab], activeIndex: 0, canGoBack: false, canGoForward: false)
            XCTAssertTrue(text.undoManager === undo)
            undo.undo()
            XCTAssertEqual(text.string, "before")
        }
    }

    func testVerticalDragCanTransferSingleTab() async {
        await MainActor.run {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let bar = TabBarView(frame: NSRect(x: 0, y: 366, width: 600, height: 34))
            window.contentView!.addSubview(bar)
            bar.titles = ["one"]
            var dropped = false
            bar.onDrop = { index, _ in dropped = index == 0; return true }
            @MainActor func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: bar.convert(point, to: nil), modifierFlags: [],
                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            bar.mouseDown(with: event(.leftMouseDown, NSPoint(x: 180, y: 20)))
            bar.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 180, y: 60)))
            bar.mouseUp(with: event(.leftMouseUp, NSPoint(x: 180, y: 60)))
            XCTAssertTrue(dropped)
            XCTAssertNotNil(bar.insertionIndex(at: window.convertPoint(toScreen: bar.convert(NSPoint(x: 180, y: 20), to: nil))))
            XCTAssertNil(bar.insertionIndex(at: window.convertPoint(toScreen: bar.convert(NSPoint(x: 180, y: 60), to: nil))))
            window.close()
        }
    }
}
