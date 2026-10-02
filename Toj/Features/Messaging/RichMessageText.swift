import Foundation
import SwiftUI

nonisolated enum RichMessageText {
    static func containsSpoiler(_ source: String) -> Bool {
        spoilerRanges(in: source).isEmpty == false
    }

    static func attributed(_ source: String, revealsSpoilers: Bool) -> AttributedString {
        let prepared = replacingSpoilers(in: source, revealsSpoilers: revealsSpoilers)
        return (try? AttributedString(
            markdown: prepared,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(prepared)
    }

    static func firstWebURL(in source: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return detector.matches(in: source, options: [], range: range)
            .lazy
            .compactMap(\.url)
            .first { url in
                guard let scheme = url.scheme?.lowercased() else { return false }
                return scheme == "https" || scheme == "http"
            }
    }

    private static func spoilerRanges(in source: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = source.startIndex
        while let start = source.range(of: "||", range: cursor..<source.endIndex),
              let end = source.range(of: "||", range: start.upperBound..<source.endIndex) {
            result.append(start.lowerBound..<end.upperBound)
            cursor = end.upperBound
        }
        return result
    }

    private static func replacingSpoilers(in source: String, revealsSpoilers: Bool) -> String {
        var result = ""
        var cursor = source.startIndex
        for range in spoilerRanges(in: source) {
            result += source[cursor..<range.lowerBound]
            let innerStart = source.index(range.lowerBound, offsetBy: 2)
            let innerEnd = source.index(range.upperBound, offsetBy: -2)
            let inner = source[innerStart..<innerEnd]
            if revealsSpoilers {
                result += inner
            } else {
                result += inner.map { $0.isWhitespace ? $0 : "▇" }
            }
            cursor = range.upperBound
        }
        result += source[cursor..<source.endIndex]
        return result
    }
}

struct SafeLinkPreviewCard: View {
    let url: URL
    var preview: CloudLinkPreview? = nil

    private var host: String {
        url.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "")
            ?? String(localized: "Link")
    }

    private var detail: String {
        if let description = preview?.description, !description.isEmpty { return description }
        let path = url.path(percentEncoded: false)
        return path.isEmpty || path == "/" ? url.absoluteString : path
    }

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TojTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(TojTheme.canvas.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview?.title ?? preview?.siteName ?? host)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TojTheme.text)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(TojTheme.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.caption.bold())
                    .foregroundStyle(TojTheme.secondaryText)
            }
            .padding(9)
            .background(TojTheme.canvas.opacity(0.42), in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13).stroke(TojTheme.hairlineStrong, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open link to \(host)")
    }
}
