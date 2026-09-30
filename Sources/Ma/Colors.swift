import AppKit

extension NSColor {
    /// 本文やラベルの文字色。真っ黒だと強すぎるので、ライトモードでは少しグレーに寄せる
    static let maText = lightModeGray(named: "maText", white: 0.2)
    /// 見出しと太字の文字色。線が太く本文より濃く見えるので、本文よりさらに明るくする
    static let maStrongText = lightModeGray(named: "maStrongText", white: 0.26)

    private static func lightModeGray(named name: String, white: CGFloat) -> NSColor {
        NSColor(name: name) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .labelColor
                : NSColor(white: white, alpha: 1)
        }
    }
}
