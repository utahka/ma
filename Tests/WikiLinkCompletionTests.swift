import AppKit
import XCTest
@testable import Ma

final class WikiLinkCompletionTests: XCTestCase {
    func testContextAndCodeExclusion() {
        func context(_ text: String) -> WikiLinkCompletion.Context? {
            WikiLinkCompletion.context(in: text, selection: NSRange(location: (text as NSString).length, length: 0))
        }
        XCTAssertEqual(context("本文 [[日 本")?.query, "日 本")
        XCTAssertEqual(context("😀 [[")?.start, 3)
        XCTAssertNil(context("[[閉じた]]"))
        XCTAssertNil(context("[[ノート|表示"))
        XCTAssertNil(context("`[[code"))
        XCTAssertNil(context("```md\n[[code"))
        XCTAssertNotNil(context("```md\ncode\n```\n[["))
    }

    func testRankingAndClosingBrackets() {
        XCTAssertEqual(WikiLinkCompletion.matching("日", paths: ["日記/別のノート", "日記", "Folder/日本語"]),
                       ["Folder/日本語", "日記", "日記/別のノート"])
        let input = "前 [[日]] 後"
        let edit = WikiLinkCompletion.edit(in: input, selection: NSRange(location: 5, length: 0), path: "Folder/日本語")!
        XCTAssertEqual((input as NSString).replacingCharacters(in: edit.range, with: edit.text), "前 [[Folder/日本語]] 後")
    }

    func testEditorCompletesWithEnterAndUndo() async {
        await MainActor.run {
            _ = NSApplication.shared
            let controller = EditorViewController()
            controller.loadViewIfNeeded()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            controller.wikiLinkPaths = { ["日記", "Folder/日本語"] }
            controller.show(OpenDocument(url: URL(fileURLWithPath: "/tmp/wiki.md"), text: "[[日"))
            @MainActor func findText(_ view: NSView) -> EditorTextView? {
                if let text = view as? EditorTextView { return text }
                return view.subviews.lazy.compactMap(findText).first
            }
            let text = findText(controller.view)!
            text.setSelectedRange(NSRange(location: 3, length: 0))
            controller.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
            text.undoManager!.groupsByEvent = false
            text.undoManager!.beginUndoGrouping()
            XCTAssertTrue(controller.textView(text, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            text.undoManager!.endUndoGrouping()
            XCTAssertEqual(text.string, "[[Folder/日本語]]")
            text.undoManager!.undo()
            XCTAssertEqual(text.string, "[[日")
            window.close()
        }
    }
}
