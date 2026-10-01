import Foundation

/// swiftc -enable-bare-slash-regex Sources/Ma/BlockMover.swift Tests/TableRowMoveTests.swift -o /tmp/ma-table-row-tests
@main
struct TableRowMoveTests {
    static func main() {
        let source = "# 前\n\n| 名前 | メモ |\n| :------- | ----: |\n| あ😀 | a<br>b |\n| B | x |\n| C | y |\n\n| 別表 |\n| --- |\n| Z |\n"
        let mover = BlockMover(source)
        let table = mover.blocks.first { $0.kind == .table }!
        let body = mover.tableBodyRows(in: table)!
        let down = mover.moveTableRow(body.lowerBound, in: table, before: body.upperBound + 1)!
        let expected = source.replacingOccurrences(of: "| あ😀 | a<br>b |\n| B | x |\n| C | y |", with: "| B | x |\n| C | y |\n| あ😀 | a<br>b |")
        precondition(down.text == expected, "見出し、列幅、別表、セル内改行を維持して末尾へ移動する")
        precondition((down.text as NSString).substring(from: down.location).hasPrefix("| あ😀 |"), "選択位置は UTF-16 で計算する")
        let unicodePrefix = mover.moveTableRow(body.upperBound, in: table, before: body.lowerBound + 1)!
        precondition((unicodePrefix.text as NSString).substring(from: unicodePrefix.location).hasPrefix("| C |"), "絵文字より後の選択位置も UTF-16 で計算する")
        let back = BlockMover(down.text).moveTableRow(body.upperBound, in: table, before: body.lowerBound)!
        precondition(back.text == source, "先頭への移動で元の本文に戻る")
        for target in [body.lowerBound, body.lowerBound + 1, table.lines.lowerBound, table.lines.upperBound + 2] {
            precondition(mover.moveTableRow(body.lowerBound, in: table, before: target) == nil, "同位置と表外には動かさない")
        }
        precondition(mover.moveTableRow(table.lines.lowerBound, in: table, before: body.upperBound) == nil)
        precondition(mover.moveTableRow(table.lines.lowerBound + 1, in: table, before: body.upperBound) == nil)
        for ending in ["", "\n"] {
            let text = "| H |\n| --- |\n| A |\n| B |" + ending
            let model = BlockMover(text)
            let lastTable = model.blocks.first!
            precondition(model.moveTableRow(2, in: lastTable, before: 4)!.text == "| H |\n| --- |\n| B |\n| A |" + ending)
        }
        for invalid in ["| text |\n| still text |\n| another |", "| H |\n| --- |"] {
            let model = BlockMover(invalid)
            precondition(model.tableBodyRows(in: model.blocks.first!) == nil)
        }
        print("表の行移動の検証が成功しました")
    }
}
