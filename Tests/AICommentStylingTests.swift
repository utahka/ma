import AppKit
import XCTest
@testable import Awai

final class AICommentStylingTests: XCTestCase {
    func testGroupedQuoteHasOneCommentAndHoverOnEveryLine() async {
        await MainActor.run {
            let input = "> 一行\n>\n>> **二行**\n> 三行"
            let result = AICommentSelection.replacement(in: input,
                range: NSRange(location: 0, length: (input as NSString).length), comment: "`code` をまとめて短く")!
            XCTAssertEqual(result.components(separatedBy: "<!-- AI: ").count - 1, 1)
            let storage = NSTextStorage(string: result)
            MarkdownStyler().apply(to: storage, activeRange: NSRange(location: NSNotFound, length: 0),
                                   availableWidth: 760, sourceMode: false)
            let group = AICommentSelection.groups(in: result).first!
            XCTAssertEqual(group.bodies.count, 3)
            for body in group.bodies {
                XCTAssertEqual(storage.attribute(.maAIComment, at: body.location, effectiveRange: nil) as? String,
                               "`code` をまとめて短く")
                XCTAssertEqual(storage.attribute(.backgroundColor, at: body.location, effectiveRange: nil) as? NSColor,
                               NSColor.maAIComment)
            }
            for marker in group.markers {
                XCTAssertEqual((storage.attribute(.font, at: marker.location, effectiveRange: nil) as? NSFont)?.pointSize, 0.01)
            }
        }
    }

    func testActiveLineAndSourceModeExposeMarkers() async {
        await MainActor.run {
            let text = "==first==<!-- AI:start -->\n==last==<!-- AI: note -->"
            let storage = NSTextStorage(string: text)
            let firstLine = (text as NSString).lineRange(for: NSRange(location: 0, length: 0))
            let group = AICommentSelection.groups(in: text).first!
            MarkdownStyler().apply(to: storage, activeRange: firstLine, availableWidth: 760, sourceMode: false)
            XCTAssertNil(storage.attribute(.maAIComment, at: group.bodies[0].location, effectiveRange: nil))
            XCTAssertEqual(storage.attribute(.maAIComment, at: group.bodies[1].location, effectiveRange: nil) as? String, "note")
            XCTAssertGreaterThan((storage.attribute(.font, at: group.markers[0].location, effectiveRange: nil) as! NSFont).pointSize, 1)
            MarkdownStyler().apply(to: storage, activeRange: firstLine, availableWidth: 760, sourceMode: true)
            XCTAssertNil(storage.attribute(.maAIComment, at: group.bodies[1].location, effectiveRange: nil))
            XCTAssertGreaterThan((storage.attribute(.font, at: group.markers[1].location, effectiveRange: nil) as! NSFont).pointSize, 1)
        }
    }

    func testLegacyCommentAndOrdinaryHighlightsStillWork() async {
        await MainActor.run {
            let text = "==old==<!-- AI: legacy -->\n==yellow==\n```md\n==code==<!-- AI:start -->\n==example==<!-- AI: ignored -->\n```"
            let storage = NSTextStorage(string: text)
            MarkdownStyler().apply(to: storage, activeRange: NSRange(location: NSNotFound, length: 0),
                                   availableWidth: 760, sourceMode: false)
            XCTAssertEqual(storage.attribute(.maAIComment, at: 2, effectiveRange: nil) as? String, "legacy")
            let yellow = (text as NSString).range(of: "yellow").location
            XCTAssertEqual(storage.attribute(.backgroundColor, at: yellow, effectiveRange: nil) as? NSColor, NSColor.maHighlight)
            XCTAssertTrue(AICommentSelection.groups(in: text).isEmpty)
            XCTAssertNil(storage.attribute(.maAIComment, at: (text as NSString).range(of: "example").location, effectiveRange: nil))
        }
    }
}
