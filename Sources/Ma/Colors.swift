import AppKit

extension NSColor {
    /// 本文やラベルの文字色。真っ黒だと強すぎるので、ライトモードでは少しグレーに寄せる
    static let maText = lightModeGray(named: "maText", white: 0.2)
    /// 見出しと太字の文字色。線が太く本文より濃く見えるので、本文よりさらに明るくする
    static let maStrongText = lightModeGray(named: "maStrongText", white: 0.26)
    /// 内部リンクと外部リンクの文字色。vault の Minimal テーマのアクセント色（hsl(201, 17%, 50%)、ダークでは明度 60%）に合わせ、下線は付けない
    static let maLink = NSColor(name: "maLink") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x88 / 255, green: 0x9E / 255, blue: 0xAA / 255, alpha: 1)
            : NSColor(srgbRed: 0x6A / 255, green: 0x86 / 255, blue: 0x95 / 255, alpha: 1)
    }

    /// Obsidian のハイライト `==文字==` の背景。Obsidian の既定（rgba(255, 208, 0, 0.4)）に合わせ、ダークでは文字が沈まないよう少し薄くする
    static let maHighlight = NSColor(name: "maHighlight") { appearance in
        NSColor(srgbRed: 1, green: 208 / 255, blue: 0, alpha: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.3 : 0.4)
    }

    /// AI へのコメントを付けた箇所の背景。Obsidian の `==` のハイライト（黄色）と見分けられるよう紫にする
    static let maAIComment = NSColor.systemPurple.withAlphaComponent(0.18)

    private static func lightModeGray(named name: String, white: CGFloat) -> NSColor {
        NSColor(name: name) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .labelColor
                : NSColor(white: white, alpha: 1)
        }
    }
}
