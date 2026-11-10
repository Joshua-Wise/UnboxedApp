//
//  HTMLConverter.swift
//  Unboxed
//
//  Converts email HTML into an NSAttributedString.
//
//  This replaces NSAttributedString's built-in HTML importer, which must run
//  on the main thread, drives WebKit synchronously and fetches remote
//  content. This converter is a plain tokenizer: it is safe on any thread,
//  never touches the network, and handles the subset of HTML that matters
//  for reading mail (text styling, links, lists, quotes, tables, inline
//  images).
//

import AppKit

nonisolated extension NSAttributedString.Key {
    /// URL of a hyperlink; used to add clickable link annotations to PDFs.
    static let unboxedLink = NSAttributedString.Key("UnboxedLinkURL")
}

nonisolated struct HTMLRenderContext {
    var baseFontSize: CGFloat = 10
    var textColor: NSColor = .black
    var maxImageWidth: CGFloat = 504
    var maxImageHeight: CGFloat = 400
    /// Content-ID → image data for `cid:` references.
    var inlineImages: [String: Data] = [:]
    /// Render bordered/data tables as real tables. Disabled as a fallback when
    /// a table cannot be paginated.
    var allowTables = true
}

nonisolated final class HTMLConverter {
    // MARK: State

    private struct Style {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var mono = false
        var pre = false
        var hidden = false
        var scale: CGFloat = 1
        var color: NSColor?
        var link: URL?
        var alignment: NSTextAlignment = .natural
        var indent = 0
        var blocks: [NSTextBlock] = []
    }

    private final class TableState {
        let table: NSTextTable?
        let outerBlocks: [NSTextBlock]
        var isData: Bool { table != nil }
        var row = -1
        var column = 0
        var maxColumns = 0
        var rowSpanEnds: [Int: Int] = [:]
        var cellStart: Int?
        var tableStart = 0
        var rowHasCell = false
        var previousCellWasShort = false

        init(table: NSTextTable?, outerBlocks: [NSTextBlock]) {
            self.table = table
            self.outerBlocks = outerBlocks
        }
    }

    private struct OpenElement {
        let tag: String
        let savedStyle: Style
        var isList = false
        var table: TableState?
    }

    private let context: HTMLRenderContext
    private let output = NSMutableAttributedString()
    private var style = Style()
    private var stack: [OpenElement] = []
    private var lists: [(ordered: Bool, counter: Int)] = []
    private var tables: [TableState] = []

    private var pendingBreaks = 0
    private var pendingSpace = false
    private var atLineStart = true
    /// Set right after a list marker so the item's first block stays on the marker's line.
    private var suppressNextBreak = false

    private var fontCache: [String: NSFont] = [:]
    private var paragraphCache: [String: NSParagraphStyle] = [:]

    private static let maxStackDepth = 256

    init(context: HTMLRenderContext) {
        self.context = context
    }

    static func attributedString(from html: String, context: HTMLRenderContext) -> NSAttributedString {
        let converter = HTMLConverter(context: context)
        converter.run(Array(html.utf8))
        return converter.finish()
    }

    // MARK: Tokenizer

    private func run(_ bytes: [UInt8]) {
        let count = bytes.count
        var index = 0
        var textStart = 0

        func flushText(upTo end: Int) {
            if end > textStart { handleText(bytes[textStart..<end]) }
        }

        while index < count {
            guard bytes[index] == 0x3C, index + 1 < count else { // "<"
                index += 1
                continue
            }
            let next = bytes[index + 1]

            if next == 0x21 || next == 0x3F { // "<!" or "<?"
                flushText(upTo: index)
                if index + 3 < count && bytes[index + 2] == 0x2D && bytes[index + 3] == 0x2D {
                    index = HTMLConverter.find(Array("-->".utf8), in: bytes, from: index + 4).map { $0 + 3 } ?? count
                } else {
                    index = HTMLConverter.findByte(0x3E, in: bytes, from: index + 2).map { $0 + 1 } ?? count
                }
                textStart = index
            } else if next == 0x2F { // closing tag
                var cursor = index + 2
                let nameStart = cursor
                while cursor < count && HTMLConverter.isNameByte(bytes[cursor]) { cursor += 1 }
                guard cursor > nameStart else {
                    index += 1
                    continue
                }
                flushText(upTo: index)
                let name = HTMLConverter.lowercasedString(bytes[nameStart..<cursor])
                index = HTMLConverter.findByte(0x3E, in: bytes, from: cursor).map { $0 + 1 } ?? count
                textStart = index
                handleClose(name)
            } else if HTMLConverter.isLetter(next) {
                flushText(upTo: index)
                var cursor = index + 1
                let nameStart = cursor
                while cursor < count && HTMLConverter.isNameByte(bytes[cursor]) { cursor += 1 }
                let name = HTMLConverter.lowercasedString(bytes[nameStart..<cursor])
                var attributes: [String: String] = [:]
                var selfClosing = false
                cursor = HTMLConverter.parseAttributes(bytes, from: cursor, into: &attributes, selfClosing: &selfClosing)
                index = cursor
                textStart = index

                if HTMLConverter.rawTextElements.contains(name) {
                    // Skip the contents entirely.
                    let closing = Array("</\(name)".utf8)
                    if let end = HTMLConverter.findCaseInsensitive(closing, in: bytes, from: index) {
                        index = HTMLConverter.findByte(0x3E, in: bytes, from: end).map { $0 + 1 } ?? count
                    } else if name == "script" || name == "style" {
                        index = count
                    }
                    // Otherwise the end tag is missing: carry on rather than drop the rest.
                    textStart = index
                    continue
                }

                if name == "table" {
                    handleTableOpen(attributes, bytes: bytes, from: index)
                } else {
                    handleOpen(name, attributes, selfClosing: selfClosing)
                }
            } else {
                index += 1
            }
        }
        flushText(upTo: count)
    }

    private static let rawTextElements: Set<String> = ["script", "style", "title", "textarea", "head", "svg", "select", "template", "object", "iframe", "noembed", "noframes", "xml"]
    private static let voidElements: Set<String> = ["br", "img", "hr", "meta", "link", "input", "col", "area", "base", "wbr", "source", "embed", "param", "track"]

    @inline(__always) private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    @inline(__always) private static func isNameByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || (byte >= 0x30 && byte <= 0x39) || byte == 0x3A || byte == 0x2D || byte == 0x5F
    }

    @inline(__always) private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    private static func lowercasedString(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
    }

    private static func findByte(_ byte: UInt8, in bytes: [UInt8], from: Int) -> Int? {
        guard from < bytes.count else { return nil }
        return bytes.withUnsafeBufferPointer { buffer -> Int? in
            guard let found = memchr(buffer.baseAddress! + from, Int32(byte), buffer.count - from) else { return nil }
            return UnsafeRawPointer(buffer.baseAddress!).distance(to: UnsafeRawPointer(found))
        }
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard from < bytes.count, bytes.count - from >= needle.count else { return nil }
        return bytes.withUnsafeBufferPointer { buffer -> Int? in
            guard let found = memmem(buffer.baseAddress! + from, buffer.count - from, needle, needle.count) else { return nil }
            return UnsafeRawPointer(buffer.baseAddress!).distance(to: UnsafeRawPointer(found))
        }
    }

    /// `needle` must be lowercase ASCII.
    private static func findCaseInsensitive(_ needle: [UInt8], in bytes: [UInt8], from: Int, limit: Int? = nil) -> Int? {
        let end = min(limit ?? bytes.count, bytes.count)
        guard !needle.isEmpty, end - from >= needle.count else { return nil }
        let first = needle[0]
        var index = from
        let last = end - needle.count
        while index <= last {
            let byte = bytes[index]
            if byte == first || (byte >= 0x41 && byte <= 0x5A && byte + 0x20 == first) {
                var matched = true
                var offset = 1
                while offset < needle.count {
                    let candidate = bytes[index + offset]
                    let lowered = candidate >= 0x41 && candidate <= 0x5A ? candidate + 0x20 : candidate
                    if lowered != needle[offset] {
                        matched = false
                        break
                    }
                    offset += 1
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }

    /// Parses attributes up to and including the closing ">". Returns the index after it.
    private static func parseAttributes(_ bytes: [UInt8], from start: Int, into attributes: inout [String: String], selfClosing: inout Bool) -> Int {
        let count = bytes.count
        var index = start
        while index < count {
            while index < count && isSpace(bytes[index]) { index += 1 }
            guard index < count else { break }
            if bytes[index] == 0x3E { return index + 1 }
            if bytes[index] == 0x2F {
                if index + 1 < count && bytes[index + 1] == 0x3E {
                    selfClosing = true
                    return index + 2
                }
                index += 1
                continue
            }
            let nameStart = index
            while index < count && !isSpace(bytes[index]) && bytes[index] != 0x3D && bytes[index] != 0x3E && bytes[index] != 0x2F { index += 1 }
            let name = lowercasedString(bytes[nameStart..<index])
            while index < count && isSpace(bytes[index]) { index += 1 }
            var value = ""
            if index < count && bytes[index] == 0x3D {
                index += 1
                while index < count && isSpace(bytes[index]) { index += 1 }
                if index < count && (bytes[index] == 0x22 || bytes[index] == 0x27) {
                    let quote = bytes[index]
                    index += 1
                    let valueStart = index
                    while index < count && bytes[index] != quote { index += 1 }
                    value = HTMLEntities.decode(bytes[valueStart..<index])
                    index += 1
                } else {
                    let valueStart = index
                    while index < count && !isSpace(bytes[index]) && bytes[index] != 0x3E { index += 1 }
                    value = HTMLEntities.decode(bytes[valueStart..<index])
                }
            }
            if !name.isEmpty && attributes[name] == nil { attributes[name] = value }
            if index == nameStart { index += 1 } // never stall on unexpected bytes
        }
        return count
    }

    // MARK: Text

    private func handleText(_ bytes: ArraySlice<UInt8>) {
        guard !style.hidden else { return }
        let text = HTMLEntities.decode(bytes)

        if style.pre {
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            guard !normalized.isEmpty else { return }
            flushBreaks()
            atLineStart = normalized.hasSuffix("\n")
            pendingSpace = false
            append(normalized)
            return
        }

        var buffer = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x20, 0x09, 0x0A, 0x0D, 0x0C:
                pendingSpace = true
            case 0x200B, 0x200C, 0x200D, 0xFEFF, 0x034F, 0x00AD:
                continue // invisible padding used in marketing mail
            default:
                if atLineStart {
                    flushBreaks()
                    atLineStart = false
                } else if pendingSpace {
                    buffer.append(" ")
                }
                pendingSpace = false
                buffer.append(scalar)
            }
        }
        if !buffer.isEmpty { append(String(buffer)) }
    }

    /// Appends text that bypasses whitespace collapsing (bullets, separators).
    private func appendLiteral(_ text: String) {
        guard !style.hidden else { return }
        if atLineStart {
            flushBreaks()
            atLineStart = false
        }
        pendingSpace = false
        append(text)
    }

    private func append(_ text: String) {
        output.append(NSAttributedString(string: text, attributes: currentAttributes()))
    }

    private func requestBreak(_ lines: Int) {
        pendingBreaks = max(pendingBreaks, lines)
        pendingSpace = false
        atLineStart = true
    }

    private func flushBreaks() {
        defer { pendingBreaks = 0 }
        if suppressNextBreak {
            suppressNextBreak = false
            return
        }
        guard output.length > 0, pendingBreaks > 0 else { return }
        let string = output.mutableString
        var trailing = 0
        var position = string.length
        while position > 0 && trailing < 2 && string.character(at: position - 1) == 0x0A {
            trailing += 1
            position -= 1
        }
        // Inside a table cell, a break never needs to reach back past the cell start.
        if let table = tables.last, table.isData, let cellStart = table.cellStart, output.length == cellStart { return }
        let needed = pendingBreaks - trailing
        if needed > 0 { append(String(repeating: "\n", count: needed)) }
    }

    private func forceLineEnd() {
        if output.length > 0 && output.mutableString.character(at: output.length - 1) != 0x0A {
            append("\n")
        }
        pendingBreaks = 0
        pendingSpace = false
        atLineStart = true
    }

    // MARK: Attributes

    private func currentAttributes() -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(),
            .paragraphStyle: paragraphStyle()
        ]
        if let link = style.link {
            attributes[.foregroundColor] = HTMLConverter.linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.unboxedLink] = link
        } else {
            attributes[.foregroundColor] = style.color ?? context.textColor
            if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        }
        if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    private static let linkColor = NSColor(srgbRed: 0, green: 0.4, blue: 0.8, alpha: 1)
    private static let quoteColor = NSColor(white: 0.4, alpha: 1)

    private func font() -> NSFont {
        let size = (context.baseFontSize * min(max(style.scale, 0.7), 2.4) * 2).rounded() / 2
        let key = "\(size)-\(style.bold)-\(style.italic)-\(style.mono)"
        if let cached = fontCache[key] { return cached }

        var font: NSFont
        if style.mono {
            font = EmailFonts.monospaced(size * 0.9, bold: style.bold)
        } else {
            font = style.bold ? EmailFonts.bold(size) : EmailFonts.regular(size)
        }
        if style.italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
        fontCache[key] = font
        return font
    }

    private func paragraphStyle() -> NSParagraphStyle {
        var key = "\(style.alignment.rawValue)-\(style.indent)"
        for block in style.blocks { key += "-\(ObjectIdentifier(block).hashValue)" }
        if let cached = paragraphCache[key] { return cached }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment
        let indent = CGFloat(min(style.indent, 8)) * 16
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.textBlocks = style.blocks
        paragraphCache[key] = paragraph
        return paragraph
    }

    // MARK: Elements

    /// Pops the top element, applying its closing behaviour.
    private func pop() {
        guard let element = stack.popLast() else { return }
        didClose(element)
        style = element.savedStyle
    }

    private func popThrough(index: Int) {
        while stack.count > index { pop() }
    }

    /// Closes the nearest open element with one of `tags`, unless a `barrier` tag is found first.
    private func autoClose(_ tags: Set<String>, barriers: Set<String>) {
        var index = stack.count - 1
        while index >= 0 {
            let tag = stack[index].tag
            if tags.contains(tag) {
                popThrough(index: index)
                return
            }
            if barriers.contains(tag) { return }
            index -= 1
        }
    }

    private func handleClose(_ name: String) {
        guard let index = stack.lastIndex(where: { $0.tag == name }) else {
            if name == "p" { requestBreak(2) }
            if name == "br" { handleLineBreak() }
            return
        }
        // Don't let a stray closing tag tear down an enclosing table.
        if name != "table", stack[index...].dropFirst().contains(where: { $0.tag == "table" }) { return }
        popThrough(index: index)
    }

    private func handleLineBreak() {
        if atLineStart {
            pendingBreaks = min(2, pendingBreaks + 1)
            if output.length == 0 { pendingBreaks = 0 }
        } else {
            requestBreak(1)
        }
    }

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "aside", "main", "nav", "address",
        "figure", "figcaption", "form", "fieldset", "dl", "dt", "dd", "center", "caption",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "hr", "table", "tr"
    ]

    private static let inlineTags: Set<String> = [
        "a", "b", "strong", "i", "em", "u", "span", "font", "code", "s", "small", "big", "sub", "sup",
        "ins", "del", "strike", "tt", "cite", "kbd", "samp", "var", "dfn", "abbr", "mark", "label"
    ]

    private func handleOpen(_ name: String, _ attributes: [String: String], selfClosing: Bool) {
        let selfClosing = selfClosing && !["td", "th", "tr", "li"].contains(name)
        if HTMLConverter.blockTags.contains(name) {
            autoClose(["p"], barriers: ["table", "td", "th", "blockquote", "li", "div"])
        }

        // Void elements never go on the stack.
        switch name {
        case "br":
            handleLineBreak()
            return
        case "hr":
            requestBreak(1)
            let saved = style
            style.color = NSColor(white: 0.7, alpha: 1)
            appendLiteral(String(repeating: "\u{2500}", count: 40))
            style = saved
            requestBreak(1)
            return
        case "img":
            handleImage(attributes)
            return
        default:
            if HTMLConverter.voidElements.contains(name) { return }
        }

        // Implicit closes for elements whose end tags are commonly omitted.
        switch name {
        case "li":
            autoClose(["li"], barriers: ["ul", "ol", "table"])
        case "tr":
            autoClose(["tr"], barriers: ["table"])
        case "td", "th":
            autoClose(["td", "th"], barriers: ["table", "tr"])
        case "dt", "dd":
            autoClose(["dt", "dd"], barriers: ["dl", "table"])
        default:
            break
        }

        // A space collapsed just before an inline element belongs to the text
        // outside it (so links and bold runs don't start with a styled space).
        if pendingSpace && !atLineStart && HTMLConverter.inlineTags.contains(name) {
            append(" ")
            pendingSpace = false
        }

        var isList = false
        let savedStyle = style
        applyCommonAttributes(attributes)

        switch name {
        case "p":
            requestBreak(2)
        case "div", "section", "article", "header", "footer", "aside", "main", "nav", "address",
             "figure", "figcaption", "form", "fieldset", "dl", "dt", "caption":
            requestBreak(1)
        case "dd":
            requestBreak(1)
            style.indent += 1
        case "center":
            requestBreak(1)
            style.alignment = .center
        case "h1", "h2", "h3", "h4", "h5", "h6":
            requestBreak(2)
            style.bold = true
            switch name {
            case "h1": style.scale *= 1.6
            case "h2": style.scale *= 1.4
            case "h3": style.scale *= 1.2
            default: style.scale *= 1.1
            }
        case "ul", "ol":
            requestBreak(lists.isEmpty ? 2 : 1)
            let start = Int(attributes["start"] ?? "") ?? 1
            lists.append((ordered: name == "ol", counter: start - 1))
            style.indent += 1
            isList = true
        case "li":
            suppressNextBreak = false
            requestBreak(1)
            if lists.isEmpty { style.indent += 1 }
        case "blockquote":
            requestBreak(2)
            style.indent += 1
            if style.color == nil { style.color = HTMLConverter.quoteColor }
        case "pre", "listing", "plaintext":
            requestBreak(2)
            style.pre = true
            style.mono = true
        case "b", "strong":
            style.bold = true
        case "i", "em", "cite", "var", "dfn":
            style.italic = true
        case "u", "ins":
            style.underline = true
        case "s", "strike", "del":
            style.strike = true
        case "code", "tt", "kbd", "samp":
            style.mono = true
        case "small", "sub", "sup":
            style.scale *= 0.85
        case "big":
            style.scale *= 1.2
        case "a":
            if let href = attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty {
                let lower = href.lowercased()
                if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
                    style.link = URL(string: href)
                        ?? href.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: $0) }
                }
            }
        case "font":
            if let color = attributes["color"].flatMap(HTMLConverter.parseColor) { style.color = color }
            if let size = attributes["size"] {
                let trimmed = size.trimmingCharacters(in: .whitespaces)
                if let value = Int(trimmed) {
                    let absolute = (trimmed.hasPrefix("+") || trimmed.hasPrefix("-")) ? 3 + value : value
                    let scales: [CGFloat] = [0.7, 0.85, 1, 1.15, 1.4, 1.8, 2.2]
                    style.scale = scales[min(max(absolute, 1), 7) - 1]
                }
            }
        case "tr":
            handleRowOpen()
        case "td", "th":
            handleCellOpen(isHeader: name == "th", attributes)
        default:
            break
        }

        if selfClosing {
            // XHTML-style empty element: undo any style change immediately.
            if isList { lists.removeLast() }
            style = savedStyle
            return
        }

        guard stack.count < HTMLConverter.maxStackDepth else {
            if isList { lists.removeLast() }
            style = savedStyle
            return
        }
        stack.append(OpenElement(tag: name, savedStyle: savedStyle, isList: isList))

        if name == "li" { emitListMarker() }
    }

    private func emitListMarker() {
        guard !style.hidden else { return }
        if var current = lists.last {
            if current.ordered {
                current.counter += 1
                lists[lists.count - 1] = current
                appendLiteral("\(current.counter).\u{00A0}")
            } else {
                appendLiteral("\u{2022}\u{00A0}")
            }
        } else {
            appendLiteral("\u{2022}\u{00A0}")
        }
        atLineStart = true // swallow whitespace right after the marker
        pendingBreaks = 0
        suppressNextBreak = true
    }

    private func didClose(_ element: OpenElement) {
        switch element.tag {
        case "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "listing", "plaintext":
            requestBreak(2)
        case "ul", "ol":
            if element.isList, !lists.isEmpty { lists.removeLast() }
            requestBreak(lists.isEmpty ? 2 : 1)
        case "div", "section", "article", "header", "footer", "aside", "main", "nav", "address",
             "figure", "figcaption", "form", "fieldset", "dl", "dt", "dd", "center", "caption":
            requestBreak(1)
        case "li":
            suppressNextBreak = false
            requestBreak(1)
        case "tr":
            handleRowClose()
        case "td", "th":
            handleCellClose()
        case "table":
            if let state = element.table { handleTableClose(state) }
        default:
            break
        }
    }

    private func applyCommonAttributes(_ attributes: [String: String]) {
        if attributes["hidden"] != nil { style.hidden = true }
        if let align = attributes["align"]?.lowercased() {
            switch align {
            case "center": style.alignment = .center
            case "right": style.alignment = .right
            case "left": style.alignment = .left
            default: break
            }
        }
        guard let css = attributes["style"], !css.isEmpty else { return }

        for declaration in css.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            if value.hasSuffix("!important") {
                value = String(value.dropLast("!important".count)).trimmingCharacters(in: .whitespaces)
            }
            switch property {
            case "display":
                if value == "none" { style.hidden = true }
            case "visibility":
                if value == "hidden" || value == "collapse" { style.hidden = true }
            case "mso-hide":
                if value == "all" { style.hidden = true }
            case "opacity":
                if Double(value) == 0 { style.hidden = true }
            case "max-height", "height":
                if property == "max-height", value == "0" || value == "0px" { style.hidden = true }
            case "font-weight":
                if value == "bold" || value == "bolder" || (Int(value) ?? 0) >= 600 {
                    style.bold = true
                } else if value == "normal" || (Int(value).map { $0 < 600 } ?? false) {
                    style.bold = false
                }
            case "font-style":
                style.italic = value == "italic" || value == "oblique"
            case "text-decoration", "text-decoration-line":
                if value.contains("underline") { style.underline = true }
                if value.contains("line-through") { style.strike = true }
                if value == "none" { style.underline = false; style.strike = false }
            case "color":
                if let color = HTMLConverter.parseColor(value) { style.color = color }
            case "text-align":
                switch value {
                case "center": style.alignment = .center
                case "right": style.alignment = .right
                case "left": style.alignment = .left
                case "justify": style.alignment = .justified
                default: break
                }
            case "font-size":
                if let scale = HTMLConverter.parseFontScale(value) {
                    if scale == 0 { style.hidden = true } else { style.scale = scale }
                }
            case "font-family":
                if value.contains("monospace") || value.contains("courier") || value.contains("consolas") || value.contains("menlo") {
                    style.mono = true
                }
            case "white-space":
                if value.hasPrefix("pre") { style.pre = true } else if value == "normal" { style.pre = false }
            default:
                break
            }
        }
    }

    /// Converts a CSS font-size into a multiple of the base size.
    private static func parseFontScale(_ value: String) -> CGFloat? {
        func number(_ suffix: String) -> CGFloat? {
            guard value.hasSuffix(suffix), let parsed = Double(value.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) else { return nil }
            return CGFloat(parsed)
        }
        if let px = number("px") { return px == 0 ? 0 : min(max(px / 15, 0.7), 2.4) }
        if let pt = number("pt") { return pt == 0 ? 0 : min(max(pt / 11, 0.7), 2.4) }
        if let em = number("rem") ?? number("em") { return em == 0 ? 0 : min(max(em, 0.7), 2.4) }
        if let percent = number("%") { return percent == 0 ? 0 : min(max(percent / 100, 0.7), 2.4) }
        if value == "0" { return 0 }
        switch value {
        case "xx-small": return 0.7
        case "x-small": return 0.75
        case "small", "smaller": return 0.85
        case "medium": return 1
        case "large", "larger": return 1.2
        case "x-large": return 1.5
        case "xx-large": return 2
        default: return nil
        }
    }

    private static let namedColors: [String: (CGFloat, CGFloat, CGFloat)] = [
        "black": (0, 0, 0), "white": (1, 1, 1), "red": (1, 0, 0), "green": (0, 0.5, 0), "blue": (0, 0, 1),
        "gray": (0.5, 0.5, 0.5), "grey": (0.5, 0.5, 0.5), "silver": (0.75, 0.75, 0.75), "maroon": (0.5, 0, 0),
        "navy": (0, 0, 0.5), "purple": (0.5, 0, 0.5), "teal": (0, 0.5, 0.5), "olive": (0.5, 0.5, 0),
        "orange": (1, 0.65, 0), "yellow": (1, 1, 0), "lime": (0, 1, 0), "aqua": (0, 1, 1), "fuchsia": (1, 0, 1),
        "darkgray": (0.66, 0.66, 0.66), "darkgrey": (0.66, 0.66, 0.66), "dimgray": (0.41, 0.41, 0.41)
    ]

    static func parseColor(_ raw: String) -> NSColor? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        var components: (CGFloat, CGFloat, CGFloat)?

        if value.hasPrefix("#") {
            let hex = value.dropFirst()
            if hex.count == 3, let number = UInt32(hex, radix: 16) {
                components = (CGFloat((number >> 8) & 0xF) / 15, CGFloat((number >> 4) & 0xF) / 15, CGFloat(number & 0xF) / 15)
            } else if hex.count >= 6, let number = UInt32(hex.prefix(6), radix: 16) {
                components = (CGFloat((number >> 16) & 0xFF) / 255, CGFloat((number >> 8) & 0xFF) / 255, CGFloat(number & 0xFF) / 255)
            }
        } else if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), let close = value.firstIndex(of: ")"), open < close {
            let parts = value[value.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
            if parts.count >= 3 {
                components = (CGFloat(parts[0]) / 255, CGFloat(parts[1]) / 255, CGFloat(parts[2]) / 255)
            }
        } else if let named = namedColors[value] {
            components = named
        }

        guard let (red, green, blue) = components else { return nil }
        // Text meant for a dark background would vanish on a white page.
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        if luminance > 0.7 { return NSColor(white: 0.2, alpha: 1) }
        return NSColor(srgbRed: min(max(red, 0), 1), green: min(max(green, 0), 1), blue: min(max(blue, 0), 1), alpha: 1)
    }

    // MARK: Images

    private func handleImage(_ attributes: [String: String]) {
        guard !style.hidden else { return }
        let source = attributes["src"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var data: Data?

        if source.lowercased().hasPrefix("cid:") {
            let contentID = String(source.dropFirst(4))
            data = context.inlineImages[contentID] ?? context.inlineImages[contentID.removingPercentEncoding ?? contentID]
        } else if source.lowercased().hasPrefix("data:image/"), let comma = source.firstIndex(of: ","),
                  source[..<comma].lowercased().hasSuffix(";base64") {
            let payload = source[source.index(after: comma)...]
            data = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters)
        }

        if let data, let image = NSImage(data: data), image.size.width >= 2, image.size.height >= 2 {
            var size = image.size
            if let width = attributes["width"].flatMap({ Double($0.replacingOccurrences(of: "px", with: "")) }), width >= 2 {
                let target = CGFloat(width) * 0.75
                if target < size.width {
                    size = CGSize(width: target, height: size.height * target / size.width)
                }
            }
            let maxWidth = max(60, context.maxImageWidth - CGFloat(min(style.indent, 8)) * 16)
            if size.width > maxWidth {
                size = CGSize(width: maxWidth, height: size.height * maxWidth / size.width)
            }
            if size.height > context.maxImageHeight {
                size = CGSize(width: size.width * context.maxImageHeight / size.height, height: context.maxImageHeight)
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: size)

            if atLineStart {
                flushBreaks()
                atLineStart = false
            }
            pendingSpace = false
            let rendered = NSMutableAttributedString(attachment: attachment)
            rendered.addAttribute(.paragraphStyle, value: paragraphStyle(), range: NSRange(location: 0, length: rendered.length))
            output.append(rendered)
            return
        }

        // Remote images are never fetched; show the alt text when there is one.
        if let alt = attributes["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty, alt.count <= 200 {
            handleText(ArraySlice(Array("[\(alt)]".utf8)))
        }
    }

    // MARK: Tables

    private func handleTableOpen(_ attributes: [String: String], bytes: [UInt8], from index: Int) {
        autoClose(["p"], barriers: ["table", "td", "th", "blockquote", "li", "div"])

        var isData = false
        if context.allowTables && !tables.contains(where: { $0.isData }) && !style.hidden {
            // Peek ahead: data tables have borders or header cells and no nested tables.
            let limit = min(bytes.count, index + 400_000)
            let end = HTMLConverter.findCaseInsensitive(Array("</table".utf8), in: bytes, from: index, limit: limit)
            if let end {
                let nested = HTMLConverter.findCaseInsensitive(Array("<table".utf8), in: bytes, from: index, limit: end) != nil
                var hasHeaderCells = false
                var probe = index
                while let position = HTMLConverter.findCaseInsensitive(Array("<th".utf8), in: bytes, from: probe, limit: end) {
                    if position + 3 < bytes.count && !HTMLConverter.isLetter(bytes[position + 3]) {
                        hasHeaderCells = true
                        break
                    }
                    probe = position + 3
                }
                let border = Int(attributes["border"]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                isData = !nested && (hasHeaderCells || border > 0)
            }
        }

        let savedStyle = style
        applyCommonAttributes(attributes)
        requestBreak(isData ? 2 : 1)

        var table: NSTextTable?
        if isData {
            let created = NSTextTable()
            created.collapsesBorders = true
            created.hidesEmptyCells = false
            table = created
            if output.length > 0 { flushBreaks() }
            forceLineEnd()
        }
        let state = TableState(table: table, outerBlocks: style.blocks)
        state.tableStart = output.length
        tables.append(state)

        guard stack.count < HTMLConverter.maxStackDepth else {
            tables.removeLast()
            style = savedStyle
            return
        }
        stack.append(OpenElement(tag: "table", savedStyle: savedStyle, table: state))
    }

    private func handleRowOpen() {
        guard let state = tables.last else {
            requestBreak(1)
            return
        }
        state.row += 1
        state.column = 0
        state.rowHasCell = false
        state.previousCellWasShort = false
        if !state.isData { requestBreak(1) }
    }

    private func handleRowClose() {
        guard let state = tables.last, !state.isData else { return }
        requestBreak(1)
    }

    private func handleCellOpen(isHeader: Bool, _ attributes: [String: String]) {
        guard let state = tables.last else { return }
        if state.row < 0 { state.row = 0 }

        guard let table = state.table else {
            // Layout table: short cells share a line, long ones stack.
            if state.rowHasCell {
                if state.previousCellWasShort && !atLineStart {
                    append("   ")
                    pendingSpace = false
                } else {
                    requestBreak(1)
                }
            }
            state.rowHasCell = true
            state.cellStart = output.length
            if isHeader { style.bold = true }
            return
        }

        while let end = state.rowSpanEnds[state.column], end >= state.row { state.column += 1 }
        let columnSpan = min(max(Int(attributes["colspan"] ?? "") ?? 1, 1), 20)
        let rowSpan = min(max(Int(attributes["rowspan"] ?? "") ?? 1, 1), 50)
        if rowSpan > 1 {
            for column in state.column..<(state.column + columnSpan) {
                state.rowSpanEnds[column] = state.row + rowSpan - 1
            }
        }

        let block = NSTextTableBlock(table: table, startingRow: state.row, rowSpan: rowSpan, startingColumn: state.column, columnSpan: columnSpan)
        block.setBorderColor(NSColor(white: 0.75, alpha: 1))
        block.setWidth(0.5, type: .absoluteValueType, for: .border)
        block.setWidth(3, type: .absoluteValueType, for: .padding)
        block.verticalAlignment = .topAlignment
        if isHeader {
            block.backgroundColor = NSColor(white: 0.94, alpha: 1)
            style.bold = true
        }

        state.column += columnSpan
        state.maxColumns = max(state.maxColumns, state.column)
        forceLineEnd()
        state.cellStart = output.length
        style.blocks = state.outerBlocks + [block]
        style.indent = 0
    }

    private func handleCellClose() {
        guard let state = tables.last, let cellStart = state.cellStart else { return }
        state.cellStart = nil

        guard state.isData else {
            // Ignore the line break that preceded the cell's own content.
            var contentStart = cellStart
            while contentStart < output.length && output.mutableString.character(at: contentStart) == 0x0A { contentStart += 1 }
            let length = output.length - contentStart
            let hasBreak = length > 0 && output.mutableString.range(of: "\n", range: NSRange(location: contentStart, length: length)).location != NSNotFound
            state.previousCellWasShort = length < 40 && !hasBreak && pendingBreaks == 0
            if !state.previousCellWasShort { requestBreak(1) }
            return
        }

        // Every cell needs at least one paragraph, terminated by a newline,
        // whose paragraph style carries the cell's text block.
        pendingBreaks = 0
        if output.length == cellStart || output.mutableString.character(at: output.length - 1) != 0x0A {
            append("\n")
        }
        let range = NSRange(location: cellStart, length: output.length - cellStart)
        let blocks = style.blocks
        output.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, subrange, _ in
            let existing = value as? NSParagraphStyle
            if let existing, existing.textBlocks.count >= blocks.count { return }
            let updated = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            updated.textBlocks = blocks
            output.addAttribute(.paragraphStyle, value: updated, range: subrange)
        }
        pendingSpace = false
        atLineStart = true
    }

    private func handleTableClose(_ state: TableState) {
        if let index = tables.lastIndex(where: { $0 === state }) { tables.remove(at: index) }
        guard let table = state.table else {
            requestBreak(1)
            return
        }

        table.numberOfColumns = max(1, state.maxColumns)
        let range = NSRange(location: state.tableStart, length: output.length - state.tableStart)
        if state.maxColumns > 10 || state.maxColumns == 0 {
            // Too wide to be legible as a grid: fall back to stacked paragraphs.
            let outer = state.outerBlocks
            output.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, subrange, _ in
                guard let existing = value as? NSParagraphStyle, let updated = existing.mutableCopy() as? NSMutableParagraphStyle else { return }
                updated.textBlocks = outer
                output.addAttribute(.paragraphStyle, value: updated, range: subrange)
            }
        }
        forceLineEnd()
        pendingBreaks = 2
    }

    // MARK: Finish

    private func finish() -> NSAttributedString {
        while !stack.isEmpty { pop() }

        // Trim trailing whitespace, unless it terminates a table cell.
        let string = output.mutableString
        var end = string.length
        while end > 0 {
            let character = string.character(at: end - 1)
            guard character == 0x0A || character == 0x20 || character == 0x09 || character == 0xA0 else { break }
            if let paragraph = output.attribute(.paragraphStyle, at: end - 1, effectiveRange: nil) as? NSParagraphStyle,
               !paragraph.textBlocks.isEmpty {
                break
            }
            end -= 1
        }
        if end < string.length {
            output.deleteCharacters(in: NSRange(location: end, length: string.length - end))
        }
        return output
    }
}

// MARK: - Entities

nonisolated enum HTMLEntities {
    static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        guard bytes.contains(0x26) else { return String(decoding: bytes, as: UTF8.self) }

        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        let end = bytes.endIndex

        while index < end {
            let byte = bytes[index]
            guard byte == 0x26 else {
                output.append(byte)
                index += 1
                continue
            }
            // Find the terminating ";" within a sensible distance.
            var cursor = index + 1
            let limit = min(end, index + 34)
            while cursor < limit && bytes[cursor] != 0x3B && bytes[cursor] != 0x26 && bytes[cursor] != 0x20 && bytes[cursor] != 0x3C {
                cursor += 1
            }
            guard cursor < limit, bytes[cursor] == 0x3B, cursor > index + 1 else {
                output.append(byte)
                index += 1
                continue
            }
            let name = String(decoding: bytes[(index + 1)..<cursor], as: UTF8.self)
            if let replacement = replacement(for: name) {
                output.append(contentsOf: Array(replacement.utf8))
                index = cursor + 1
            } else {
                output.append(byte)
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func replacement(for name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let code: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                code = UInt32(digits.dropFirst(), radix: 16)
            } else {
                code = UInt32(digits, radix: 10)
            }
            guard var value = code else { return nil }
            // Numeric references in the C1 range are really Windows-1252.
            if (0x80...0x9F).contains(value), let mapped = windows1252[value] { value = mapped }
            guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
            return String(Character(scalar))
        }
        return named[name]
    }

    private static let windows1252: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
        0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D,
        0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
        0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178
    ]

    private static let named: [String: String] = [
        "nbsp": "\u{00A0}", "lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
        "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›",
        "bull": "•", "middot": "·", "prime": "′", "Prime": "″", "dagger": "†", "Dagger": "‡",
        "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "curren": "¤",
        "sect": "§", "para": "¶", "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "micro": "µ",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "sup1": "¹", "sup2": "²", "sup3": "³",
        "larr": "←", "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔", "rArr": "⇒", "lArr": "⇐",
        "ne": "≠", "le": "≤", "ge": "≥", "infin": "∞", "sum": "∑", "prod": "∏", "minus": "−", "asymp": "≈",
        "iexcl": "¡", "iquest": "¿", "ordf": "ª", "ordm": "º", "not": "¬", "macr": "¯", "acute": "´", "cedil": "¸",
        "brvbar": "¦", "uml": "¨", "check": "✓", "hearts": "♥", "star": "☆", "starf": "★",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "shy": "\u{00AD}", "lrm": "", "rlm": "",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ",
        "Ccedil": "Ç", "ccedil": "ç", "ETH": "Ð", "eth": "ð", "Ntilde": "Ñ", "ntilde": "ñ",
        "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë",
        "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï", "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï",
        "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø", "OElig": "Œ",
        "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø", "oelig": "œ",
        "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü",
        "Yacute": "Ý", "yacute": "ý", "yuml": "ÿ", "Yuml": "Ÿ", "szlig": "ß", "THORN": "Þ", "thorn": "þ",
        "Scaron": "Š", "scaron": "š", "Zcaron": "Ž", "zcaron": "ž",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "lambda": "λ", "mu": "μ",
        "pi": "π", "sigma": "σ", "tau": "τ", "phi": "φ", "omega": "ω", "Delta": "Δ", "Omega": "Ω", "Sigma": "Σ"
    ]
}
