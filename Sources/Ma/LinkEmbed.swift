import AppKit
import Yams

/// Obsidian の Link Embed プラグインの ```embed ブロック。カーソルがないときはカードとして描く
final class EmbedCard: NSObject, @unchecked Sendable {
    /// カードを載せる最初の行の高さ（上下の余白を含む）
    static let lineHeight: CGFloat = 116
    static let verticalMargin: CGFloat = 6

    let title: String
    let summary: String
    let url: String
    let image: String
    let favicon: String

    init(title: String, summary: String, url: String, image: String, favicon: String) {
        self.title = title
        self.summary = summary
        self.url = url
        self.image = image
        self.favicon = favicon
    }

    /// ブロックの中身（フェンスの間の YAML）を読む。url がなければカードにしない
    static func parse(_ yaml: String) -> EmbedCard? {
        guard let map = (try? Yams.load(yaml: yaml)) as? [String: Any] else { return nil }
        func value(_ key: String) -> String {
            guard let raw = map[key] else { return "" }
            return (raw as? String ?? "\(raw)").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let url = value("url")
        guard !url.isEmpty else { return nil }
        return EmbedCard(title: value("title"), summary: value("description"), url: url,
                         image: value("image"), favicon: value("favicon"))
    }

    var host: String {
        guard let host = URL(string: url)?.host() else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? EmbedCard else { return false }
        return title == other.title && summary == other.summary && url == other.url && image == other.image
            && favicon == other.favicon
    }

    override var hash: Int { url.hashValue }

    // MARK: - 描画

    /// カードの枠（フラグメント内の座標）
    static func cardRect(left: CGFloat, width: CGFloat) -> CGRect {
        CGRect(x: left, y: verticalMargin, width: width, height: lineHeight - verticalMargin * 2)
    }

    @MainActor
    func draw(in rect: CGRect) {
        let radius: CGFloat = 8
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor.quaternarySystemFill.setFill()
        border.fill()

        var textRect = rect.insetBy(dx: 16, dy: 14)
        if let image = EmbedImageCache.shared.image(for: image) {
            // 右側に、縦を合わせて最大 16:10 の幅で切り抜いて置く
            let width = min(rect.height * 1.6, rect.width * 0.35)
            let frame = CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            NSBezierPath(rect: frame).addClip()
            Self.drawAspectFill(image, in: frame)
            NSGraphicsContext.restoreGraphicsState()
            textRect.size.width -= width
        }

        let wrapping = NSMutableParagraphStyle()
        wrapping.lineBreakMode = .byWordWrapping
        let title = NSAttributedString(string: self.title.isEmpty ? url : self.title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.maStrongText,
            .paragraphStyle: wrapping,
        ])
        let titleHeight = ceil(NSFont.systemFont(ofSize: 14, weight: .semibold).boundingRectForFont.height)
        title.draw(with: CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: titleHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        let footer: CGFloat = 16
        if !summary.isEmpty {
            let summary = NSAttributedString(string: self.summary, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: wrapping,
            ])
            let top = textRect.minY + titleHeight + 4
            summary.draw(with: CGRect(x: textRect.minX, y: top, width: textRect.width,
                                      height: max(0, textRect.maxY - footer - 4 - top)),
                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        var x = textRect.minX
        if let icon = EmbedImageCache.shared.image(for: favicon) {
            icon.draw(in: CGRect(x: x, y: textRect.maxY - 14, width: 14, height: 14), from: .zero,
                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 20
        }
        let host = NSAttributedString(string: self.host, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: wrapping,
        ])
        host.draw(with: CGRect(x: x, y: textRect.maxY - footer, width: max(1, textRect.maxX - x), height: footer),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        NSColor.separatorColor.setStroke()
        border.lineWidth = 1
        border.stroke()
    }

    private static func drawAspectFill(_ image: NSImage, in frame: CGRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(frame.width / size.width, frame.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        image.draw(in: CGRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2,
                              width: drawn.width, height: drawn.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension Notification.Name {
    /// カードの画像を読み込み終えたとき。object は画像の URL の文字列
    static let maEmbedImageLoaded = Notification.Name("ma.embedImageLoaded")
}

/// カードの画像を非同期で読み込み、アプリの起動中は覚えておく
@MainActor
final class EmbedImageCache {
    static let shared = EmbedImageCache()

    private var images: [String: NSImage] = [:]
    private var requested: Set<String> = []

    /// 読み込み済みなら画像を返す。まだなら読み込みを始め、終わったら `.maEmbedImageLoaded` を送る
    func image(for string: String) -> NSImage? {
        guard !string.isEmpty else { return nil }
        if let image = images[string] { return image }
        guard !requested.contains(string), var components = URLComponents(string: string) else { return nil }
        requested.insert(string)
        // ATS で http は読めないので https で試す
        if components.scheme == "http" { components.scheme = "https" }
        guard let url = components.url, url.scheme == "https" else { return nil }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            images[string] = image
            NotificationCenter.default.post(name: .maEmbedImageLoaded, object: string)
        }
        return nil
    }
}
