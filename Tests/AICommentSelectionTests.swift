// 実行: tmpdir=$(mktemp -d); cp Tests/AICommentSelectionTests.swift "$tmpdir/main.swift"
// swiftc Sources/Ma/AICommentSelection.swift "$tmpdir/main.swift" -o "$tmpdir/check" && "$tmpdir/check"
import Foundation
func check(_ input: String, _ expected: String, range: NSRange? = nil) {
    let result = AICommentSelection.replacement(in: input, range: range ?? NSRange(location: 0, length: (input as NSString).length), comment: "短く")
    precondition(result == expected, "\(String(describing: result)) != \(expected)")
}
check("> 次回の設定\n> 高評価よろしく\n> バイバイ！", "> ==次回の設定==<!-- AI:start -->\n> ==高評価よろしく==\n> ==バイバイ！==<!-- AI: 短く -->")
check("> 一行\n>\n>> 入れ子\n", "> ==一行==<!-- AI:start -->\n>\n>> ==入れ子==<!-- AI: 短く -->\n")
check("  文字  ", "  ==文字==<!-- AI: 短く -->  ")
check("あいう\n> 次", "==いう==<!-- AI:start -->\n> ==次==<!-- AI: 短く -->", range: NSRange(location: 1, length: 6))
check("絵文字😀\r\n> 日本語", "==絵文字😀==<!-- AI:start -->\r\n> ==日本語==<!-- AI: 短く -->")
precondition(AICommentSelection.replacement(in: "==既存==", range: NSRange(location: 0, length: 6), comment: "x") == nil)
precondition(AICommentSelection.replacement(in: "> \n> ", range: NSRange(location: 0, length: 5), comment: "x") == nil)
precondition(AICommentSelection.replacement(in: "x", range: NSRange(location: NSNotFound, length: 1), comment: "x") == nil)
let grouped = "> ==一行==<!-- AI:start -->\n>\n>> ==二行==<!-- AI: 短く -->"
let groups = AICommentSelection.groups(in: grouped)
precondition(groups.count == 1 && groups[0].bodies.count == 2 && groups[0].comment == "短く")
precondition(AICommentSelection.groups(in: "```md\n" + grouped + "\n```\n").isEmpty)
precondition(AICommentSelection.groups(in: "`==例==<!-- AI:start -->`\n==終わり==<!-- AI: x -->").isEmpty)
precondition(AICommentSelection.groups(in: grouped + "\n" + grouped).count == 2)
check("前\n\n後", "==前==<!-- AI:start -->\n\n==後==<!-- AI: 短く -->")
precondition(AICommentSelection.groups(in: grouped.replacingOccurrences(of: "短く", with: "`code` を短く"))[0].comment == "`code` を短く")
print("AI comment: 14 checks passed")
