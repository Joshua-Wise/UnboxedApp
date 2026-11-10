//
//  PDFRenderer.swift
//  Unboxed
//
//  Lays out an email with TextKit and draws it straight into a Core Graphics
//  PDF context.
//
//  Layout happens exactly once per email: one text container per page is
//  added until all text is placed. Nothing here needs the main thread, so
//  emails can be laid out in parallel.
//

import AppKit

nonisolated enum PDFPageMetrics {
    /// US Letter at 72 DPI.
    static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    /// 0.75" margins.
    static let margin: CGFloat = 54
    static let contentSize = CGSize(width: pageRect.width - 2 * margin, height: pageRect.height - 2 * margin)
    static let maxPagesPerEmail = 3000
}

/// The laid-out pages of one email. Use from one thread at a time.
nonisolated final class EmailLayout {
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    /// The content did not fit within the page limit.
    fileprivate(set) var truncated = false
    /// Layout could not make progress (e.g. an unbreakable block taller than a page).
    fileprivate(set) var stalled = false

    var pageCount: Int { layoutManager.textContainers.count }

    fileprivate init(content: NSAttributedString) {
        storage = NSTextStorage(attributedString: content)
        layoutManager = NSLayoutManager()
        layoutManager.backgroundLayoutEnabled = false
        layoutManager.allowsNonContiguousLayout = false
        layoutManager.usesFontLeading = true
        storage.addLayoutManager(layoutManager)
    }
}

/// Fonts used for rendered email text.
///
/// Helvetica Neue is used rather than the system font: shaping the system
/// font takes a process-wide lock, which serialises layout across threads,
/// and it embeds less compactly in PDFs.
nonisolated enum EmailFonts {
    static func regular(_ size: CGFloat) -> NSFont {
        NSFont(name: "HelveticaNeue", size: size) ?? NSFont.systemFont(ofSize: size)
    }

    static func bold(_ size: CGFloat) -> NSFont {
        NSFont(name: "HelveticaNeue-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
    }

    static func monospaced(_ size: CGFloat, bold: Bool) -> NSFont {
        NSFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}

nonisolated enum PDFRenderer {
    // MARK: Content

    private static func paragraph(spacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.paragraphSpacing = spacing
        return style
    }

    static func bodyAttributes(fontSize: CGFloat, color: NSColor = .black) -> [NSAttributedString.Key: Any] {
        [.font: EmailFonts.regular(fontSize), .foregroundColor: color, .paragraphStyle: paragraph(spacing: 2)]
    }

    /// The message body (all segments) as attributed text.
    static func bodyContent(for email: ParsedEmail, fontSize: CGFloat, maxImageWidth: CGFloat, allowTables: Bool = true) -> NSAttributedString {
        let attributes = bodyAttributes(fontSize: fontSize)
        let result = NSMutableAttributedString()

        for segment in email.segments {
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n", attributes: attributes)) }
            if segment.isHTML {
                var context = HTMLRenderContext()
                context.baseFontSize = fontSize
                context.maxImageWidth = maxImageWidth
                context.inlineImages = email.inlineImages
                context.allowTables = allowTables
                result.append(HTMLConverter.attributedString(from: segment.text, context: context))
            } else {
                let text = segment.text
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(NSAttributedString(string: text, attributes: attributes))
            }
        }

        if result.length == 0 {
            result.append(NSAttributedString(string: "(No content)", attributes: attributes))
        }
        return result
    }

    /// Everything that goes into the PDF for one email: title, headers, body
    /// and (optionally) merged attachments.
    static func content(for email: ParsedEmail, title: String, mergeAttachments: Bool, allowTables: Bool = true) -> NSAttributedString {
        let summary = email.summary
        let content = NSMutableAttributedString()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: EmailFonts.bold(16),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph(spacing: 12)
        ]
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: EmailFonts.regular(10),
            .foregroundColor: NSColor.darkGray,
            .paragraphStyle: paragraph(spacing: 4)
        ]
        let bodyAttributes = bodyAttributes(fontSize: 10)

        content.append(NSAttributedString(string: "\(title)\n\n", attributes: titleAttributes))

        if !summary.from.isEmpty {
            content.append(NSAttributedString(string: "From: \(summary.from)\n", attributes: headerAttributes))
        }
        if !summary.to.isEmpty {
            content.append(NSAttributedString(string: "To: \(summary.to)\n", attributes: headerAttributes))
        }
        if let cc = summary.cc, !cc.isEmpty {
            content.append(NSAttributedString(string: "Cc: \(cc)\n", attributes: headerAttributes))
        }
        if !summary.dateString.isEmpty {
            content.append(NSAttributedString(string: "Date: \(summary.formattedDate)\n", attributes: headerAttributes))
        }
        if !summary.attachments.isEmpty {
            content.append(NSAttributedString(string: "Attachments: \(summary.attachments.joined(separator: ", "))\n", attributes: headerAttributes))
        }

        content.append(NSAttributedString(string: "\n", attributes: headerAttributes))
        content.append(NSAttributedString(string: "Message:\n", attributes: headerAttributes))
        content.append(bodyContent(for: email, fontSize: 10, maxImageWidth: PDFPageMetrics.contentSize.width, allowTables: allowTables))
        content.append(NSAttributedString(string: "\n", attributes: bodyAttributes))

        if mergeAttachments {
            let mergeable = email.attachments.filter { $0.canMergeIntoPDF }
            if !mergeable.isEmpty {
                content.append(NSAttributedString(string: "\n" + String(repeating: "\u{2500}", count: 50) + "\n", attributes: headerAttributes))
                content.append(NSAttributedString(string: "ATTACHMENTS\n\n", attributes: titleAttributes))

                for attachment in mergeable {
                    content.append(NSAttributedString(string: "\n[\(attachment.filename)]\n", attributes: headerAttributes))

                    if attachment.isImage {
                        guard let image = NSImage(data: attachment.data), image.size.width > 0, image.size.height > 0 else { continue }
                        var size = image.size
                        let maxWidth = PDFPageMetrics.contentSize.width
                        let maxHeight: CGFloat = 300
                        if size.width > maxWidth {
                            size = CGSize(width: maxWidth, height: size.height * maxWidth / size.width)
                        }
                        if size.height > maxHeight {
                            size = CGSize(width: size.width * maxHeight / size.height, height: maxHeight)
                        }
                        let textAttachment = NSTextAttachment()
                        textAttachment.image = image
                        textAttachment.bounds = CGRect(origin: .zero, size: size)
                        content.append(NSAttributedString(attachment: textAttachment))
                        content.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
                    } else {
                        let text = TextDecoding.string(attachment.data, charset: attachment.charset)
                        let shown = text.count > 5000 ? String(text.prefix(5000)) + "\n...[truncated]" : text
                        content.append(NSAttributedString(string: shown + "\n\n", attributes: bodyAttributes))
                    }
                }
            }
        }

        return content
    }

    // MARK: Layout

    static func layout(_ content: NSAttributedString) -> EmailLayout {
        let layout = EmailLayout(content: content)
        let manager = layout.layoutManager
        let totalGlyphs = manager.numberOfGlyphs

        while true {
            let container = NSTextContainer(size: PDFPageMetrics.contentSize)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            let range = manager.glyphRange(for: container)

            if NSMaxRange(range) >= totalGlyphs { break }
            if range.length == 0 {
                layout.stalled = true
                if manager.textContainers.count > 1 {
                    manager.removeTextContainer(at: manager.textContainers.count - 1)
                }
                break
            }
            if manager.textContainers.count >= PDFPageMetrics.maxPagesPerEmail {
                layout.truncated = true
                break
            }
        }
        return layout
    }

    /// Builds and lays out one email, falling back to simpler table rendering
    /// if a table cannot be paginated.
    static func layout(email: ParsedEmail, title: String, mergeAttachments: Bool) -> EmailLayout {
        let first = layout(content(for: email, title: title, mergeAttachments: mergeAttachments))
        guard first.stalled, email.segments.contains(where: \.isHTML) else { return first }
        return layout(content(for: email, title: title, mergeAttachments: mergeAttachments, allowTables: false))
    }

    // MARK: Drawing

    static func makeContext(url: URL, title: String? = nil) -> CGContext? {
        var mediaBox = PDFPageMetrics.pageRect
        var info: [CFString: Any] = [kCGPDFContextCreator: "Unboxed"]
        if let title { info[kCGPDFContextTitle] = title }
        return CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary)
    }

    private static let footerAttributes: [NSAttributedString.Key: Any] = [
        .font: EmailFonts.regular(8),
        .foregroundColor: NSColor.gray
    ]

    /// Draws every page of `layout` into `context`.
    static func draw(_ layout: EmailLayout, in context: CGContext) {
        let manager = layout.layoutManager
        let pageRect = PDFPageMetrics.pageRect
        let margin = PDFPageMetrics.margin
        let origin = CGPoint(x: margin, y: margin)
        let pageCount = layout.pageCount

        for (pageIndex, container) in manager.textContainers.enumerated() {
            let glyphRange = manager.glyphRange(for: container)

            context.beginPDFPage(nil)
            context.saveGState()
            // TextKit draws in a flipped (top-left origin) coordinate system.
            context.translateBy(x: 0, y: pageRect.height)
            context.scaleBy(x: 1, y: -1)

            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics

            if glyphRange.length > 0 {
                manager.drawBackground(forGlyphRange: glyphRange, at: origin)
                manager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
            }

            if pageCount > 1 {
                var footer = "Page \(pageIndex + 1) of \(pageCount)"
                if layout.truncated && pageIndex == pageCount - 1 { footer += " (content truncated at the page limit)" }
                NSAttributedString(string: footer, attributes: footerAttributes)
                    .draw(at: CGPoint(x: margin, y: pageRect.height - 35))
            }

            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()

            // Clickable links (default PDF coordinates: bottom-left origin).
            if glyphRange.length > 0 {
                let characterRange = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                layout.storage.enumerateAttribute(.unboxedLink, in: characterRange, options: []) { value, range, _ in
                    guard let url = value as? URL else { return }
                    let linkGlyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    manager.enumerateEnclosingRects(
                        forGlyphRange: linkGlyphs,
                        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                        in: container
                    ) { rect, _ in
                        let linkRect = CGRect(
                            x: margin + rect.minX,
                            y: pageRect.height - margin - rect.maxY,
                            width: rect.width,
                            height: rect.height
                        )
                        context.setURL(url as CFURL, for: linkRect)
                    }
                }
            }

            context.endPDFPage()
        }
    }
}
