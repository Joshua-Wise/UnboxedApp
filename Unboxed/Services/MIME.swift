//
//  MIME.swift
//  Unboxed
//
//  Byte-level MIME parsing: headers, encoded words, transfer encodings,
//  character sets and recursive multipart structure.
//
//  Everything here works directly on the bytes of the memory-mapped MBOX file
//  and only produces Strings/Data for the pieces that are actually needed.
//

import Foundation

// MARK: - Byte spans

/// A non-owning view into bytes of a memory-mapped file.
/// Only valid while the owning `MappedFile` is alive.
nonisolated struct ByteSpan: @unchecked Sendable {
    let base: UnsafePointer<UInt8>
    let count: Int

    private static let emptyBase: UnsafePointer<UInt8> = {
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        pointer.pointee = 0
        return UnsafePointer(pointer)
    }()

    static var empty: ByteSpan { ByteSpan(base: emptyBase, count: 0) }

    @inline(__always) subscript(index: Int) -> UInt8 { base[index] }

    var isEmpty: Bool { count == 0 }
    var buffer: UnsafeBufferPointer<UInt8> { UnsafeBufferPointer(start: base, count: count) }

    func slice(_ lower: Int, _ upper: Int) -> ByteSpan {
        let lo = max(0, min(lower, count))
        let hi = max(lo, min(upper, count))
        return ByteSpan(base: base + lo, count: hi - lo)
    }

    func index(of byte: UInt8, from: Int, to: Int? = nil) -> Int? {
        let end = min(to ?? count, count)
        guard from >= 0, from < end else { return nil }
        guard let found = memchr(base + from, Int32(byte), end - from) else { return nil }
        return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
    }

    func find(_ needle: [UInt8], from: Int, to: Int? = nil) -> Int? {
        let end = min(to ?? count, count)
        guard !needle.isEmpty, from >= 0, end - from >= needle.count else { return nil }
        return needle.withUnsafeBufferPointer { pattern -> Int? in
            guard let found = memmem(base + from, end - from, pattern.baseAddress!, pattern.count) else { return nil }
            return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
        }
    }

    func hasPrefix(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
        guard offset >= 0, offset + prefix.count <= count else { return false }
        return prefix.withUnsafeBufferPointer { memcmp(base + offset, $0.baseAddress!, $0.count) == 0 }
    }

    /// End of the line starting at `from`: `contentEnd` excludes the line
    /// terminator, `next` is the start of the following line.
    func lineEnd(from: Int) -> (contentEnd: Int, next: Int) {
        guard let newline = index(of: 0x0A, from: from) else { return (count, count) }
        var end = newline
        if end > from && base[end - 1] == 0x0D { end -= 1 }
        return (end, newline + 1)
    }

    func data() -> Data {
        count == 0 ? Data() : Data(bytes: base, count: count)
    }
}

// MARK: - Character sets

nonisolated enum TextDecoding {
    static func encoding(forCharset name: String) -> String.Encoding? {
        let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).lowercased()
        switch cleaned {
        case "", "utf-8", "utf8", "us-ascii", "ascii", "ansi_x3.4-1968":
            return .utf8
        case "iso-8859-1", "latin1", "windows-1252", "cp1252", "cp-1252":
            // Mail clients routinely label Windows-1252 text as ISO-8859-1.
            return .windowsCP1252
        default:
            break
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(cleaned as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    static func string(_ bytes: UnsafeBufferPointer<UInt8>, charset: String?) -> String {
        guard !bytes.isEmpty else { return "" }
        let declared = charset.flatMap { encoding(forCharset: $0) }
        if let declared, declared != .utf8, let decoded = String(bytes: bytes, encoding: declared) {
            return decoded
        }
        if let utf8 = String(bytes: bytes, encoding: .utf8) { return utf8 }
        if declared == .utf8 {
            // Declared UTF-8 but damaged: keep what we can.
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(bytes: bytes, encoding: .windowsCP1252)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    static func string(_ data: Data, charset: String?) -> String {
        data.withUnsafeBytes { raw in
            string(raw.bindMemory(to: UInt8.self), charset: charset)
        }
    }

    static func string(_ bytes: [UInt8], charset: String?) -> String {
        bytes.withUnsafeBufferPointer { string($0, charset: charset) }
    }
}

// MARK: - Transfer encodings

nonisolated enum TransferDecoding {
    @inline(__always) private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    /// Single-pass quoted-printable decoder (RFC 2045).
    static func quotedPrintable(_ input: UnsafeBufferPointer<UInt8>, headerMode: Bool = false) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(input.count)
        let count = input.count
        var index = 0
        while index < count {
            let byte = input[index]
            if byte == 0x3D { // "="
                if index + 2 < count, let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
                // Soft line break: "=" followed by optional whitespace and a newline.
                var probe = index + 1
                while probe < count && (input[probe] == 0x20 || input[probe] == 0x09) { probe += 1 }
                if probe < count && input[probe] == 0x0D { probe += 1 }
                if probe < count && input[probe] == 0x0A {
                    index = probe + 1
                    continue
                }
                if probe >= count {
                    // Trailing "=" at the end of the data.
                    index = count
                    continue
                }
                output.append(byte)
                index += 1
            } else if headerMode && byte == 0x5F { // "_" means space in encoded words
                output.append(0x20)
                index += 1
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    static func base64(_ input: UnsafeBufferPointer<UInt8>) -> Data {
        guard let base = input.baseAddress, input.count > 0 else { return Data() }
        let wrapped = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: input.count, deallocator: .none)
        if let decoded = Data(base64Encoded: wrapped, options: .ignoreUnknownCharacters) {
            return decoded
        }
        // Damaged padding or truncated data: keep only alphabet characters and re-pad.
        var filtered = [UInt8]()
        filtered.reserveCapacity(input.count)
        for byte in input {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2F:
                filtered.append(byte)
            case 0x2D: filtered.append(0x2B) // url-safe "-"
            case 0x5F: filtered.append(0x2F) // url-safe "_"
            default: break
            }
        }
        let remainder = filtered.count % 4
        if remainder == 1 { filtered.removeLast() }
        while filtered.count % 4 != 0 { filtered.append(0x3D) }
        return Data(base64Encoded: Data(filtered)) ?? Data()
    }
}

// MARK: - Headers

nonisolated struct MIMEHeaders: Sendable {
    /// Lowercased field name → unfolded raw value (first occurrence wins).
    private(set) var fields: [String: String] = [:]

    subscript(name: String) -> String? { fields[name] }
    var isEmpty: Bool { fields.isEmpty }

    private static let maxValueBytes = 64 * 1024

    /// Parses a header block starting at `start`. Returns the headers and the
    /// offset where the body begins.
    static func parse(_ span: ByteSpan, from start: Int = 0) -> (headers: MIMEHeaders, bodyStart: Int) {
        var headers = MIMEHeaders()
        var position = start
        var currentName: String?
        var currentValue = [UInt8]()

        func flush() {
            guard let name = currentName else { return }
            if headers.fields[name] == nil {
                let value = TextDecoding.string(currentValue, charset: nil)
                headers.fields[name] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentName = nil
            currentValue.removeAll(keepingCapacity: true)
        }

        while position < span.count {
            let (contentEnd, next) = span.lineEnd(from: position)
            if contentEnd == position {
                flush()
                return (headers, next)
            }

            let first = span[position]
            if first == 0x20 || first == 0x09 {
                // Folded continuation of the previous header.
                if currentName != nil && currentValue.count < maxValueBytes {
                    var contentStart = position
                    while contentStart < contentEnd && (span[contentStart] == 0x20 || span[contentStart] == 0x09) {
                        contentStart += 1
                    }
                    currentValue.append(0x20)
                    currentValue.append(contentsOf: UnsafeBufferPointer(start: span.base + contentStart, count: contentEnd - contentStart))
                }
                position = next
                continue
            }

            if let colon = span.index(of: 0x3A, from: position, to: contentEnd),
               let name = fieldName(span, from: position, to: colon) {
                flush()
                currentName = name
                let valueLength = min(contentEnd - (colon + 1), maxValueBytes)
                currentValue.append(contentsOf: UnsafeBufferPointer(start: span.base + colon + 1, count: valueLength))
            } else if position == start && (span.hasPrefix(fromPrefix, at: position) || span.hasPrefix(escapedFromPrefix, at: position)) {
                // Stray mbox separator line; ignore.
            } else {
                // Not a header line: the blank separator line is missing, so
                // treat everything from here on as the body.
                flush()
                return (headers, position)
            }
            position = next
        }

        flush()
        return (headers, span.count)
    }

    private static let fromPrefix = Array("From ".utf8)
    private static let escapedFromPrefix = Array(">From ".utf8)

    private static func fieldName(_ span: ByteSpan, from start: Int, to colon: Int) -> String? {
        var end = colon
        while end > start && (span[end - 1] == 0x20 || span[end - 1] == 0x09) { end -= 1 }
        let length = end - start
        guard length >= 1, length <= 76 else { return nil }
        var name = [UInt8]()
        name.reserveCapacity(length)
        for index in start..<end {
            let byte = span[index]
            guard byte > 0x20, byte < 0x7F else { return nil }
            name.append(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte)
        }
        return String(decoding: name, as: UTF8.self)
    }
}

// MARK: - Encoded words (RFC 2047)

nonisolated enum EncodedWords {
    static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let bytes = Array(input.utf8)
        let count = bytes.count
        var result = ""
        var literalStart = 0
        var index = 0

        // Adjacent words in the same charset are joined before decoding so
        // multi-byte characters split across words survive.
        var pendingBytes = [UInt8]()
        var pendingCharset: String?

        func flushPending() {
            if let charset = pendingCharset {
                result += TextDecoding.string(pendingBytes, charset: charset)
                pendingBytes.removeAll(keepingCapacity: true)
                pendingCharset = nil
            }
        }

        func appendLiteral(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let slice = bytes[range]
            if pendingCharset != nil && slice.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                return // whitespace between encoded words is dropped
            }
            flushPending()
            result += String(decoding: slice, as: UTF8.self)
        }

        while index + 1 < count {
            guard bytes[index] == 0x3D, bytes[index + 1] == 0x3F,
                  let word = parseWord(bytes, at: index) else {
                index += 1
                continue
            }
            appendLiteral(literalStart..<index)
            if let charset = pendingCharset, charset != word.charset { flushPending() }
            pendingCharset = word.charset
            pendingBytes.append(contentsOf: word.bytes)
            index = word.end
            literalStart = index
        }

        if literalStart < count {
            let tail = literalStart..<count
            if pendingCharset != nil && bytes[tail].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                flushPending()
            } else {
                flushPending()
                result += String(decoding: bytes[tail], as: UTF8.self)
            }
        } else {
            flushPending()
        }
        return result
    }

    private static func parseWord(_ bytes: [UInt8], at start: Int) -> (charset: String, bytes: [UInt8], end: Int)? {
        let count = bytes.count
        var index = start + 2
        let charsetStart = index
        while index < count && bytes[index] != 0x3F {
            if bytes[index] <= 0x20 || index - charsetStart > 40 { return nil }
            index += 1
        }
        guard index < count, index > charsetStart else { return nil }
        var charset = String(decoding: bytes[charsetStart..<index], as: UTF8.self)
        if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) } // language suffix
        index += 1
        guard index + 1 < count, bytes[index + 1] == 0x3F else { return nil }
        let encoding = bytes[index] | 0x20
        guard encoding == 0x71 || encoding == 0x62 else { return nil } // q or b
        index += 2
        let textStart = index
        while index + 1 < count && !(bytes[index] == 0x3F && bytes[index + 1] == 0x3D) {
            if bytes[index] == 0x0A || bytes[index] == 0x0D { return nil }
            index += 1
        }
        guard index + 1 < count else { return nil }
        let text = bytes[textStart..<index]
        let decoded: [UInt8] = text.withUnsafeBufferPointer { buffer in
            if encoding == 0x71 {
                return TransferDecoding.quotedPrintable(buffer, headerMode: true)
            }
            return [UInt8](TransferDecoding.base64(buffer))
        }
        return (charset, decoded, index + 2)
    }
}

// MARK: - Structured header values

/// A header like `text/html; charset="utf-8"; name*=UTF-8''r%C3%A9sum%C3%A9.pdf`.
nonisolated struct HeaderValue: Sendable {
    let value: String
    let params: [String: String]

    init(_ raw: String?) {
        guard let raw, !raw.isEmpty else {
            value = ""
            params = [:]
            return
        }
        let bytes = Array(raw.utf8)
        let count = bytes.count
        var index = 0
        while index < count && bytes[index] != 0x3B { index += 1 }
        value = String(decoding: bytes[0..<index], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        var plain: [String: String] = [:]
        // RFC 2231 pieces: base name → [(index, isExtended, value)]
        var extended: [String: [(Int, Bool, String)]] = [:]

        while index < count {
            // Skip separators.
            while index < count && (bytes[index] == 0x3B || bytes[index] == 0x20 || bytes[index] == 0x09) { index += 1 }
            let nameStart = index
            while index < count && bytes[index] != 0x3D && bytes[index] != 0x3B { index += 1 }
            let name = String(decoding: bytes[nameStart..<index], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard index < count, bytes[index] == 0x3D else { continue }
            index += 1
            while index < count && (bytes[index] == 0x20 || bytes[index] == 0x09) { index += 1 }

            var valueBytes = [UInt8]()
            if index < count && bytes[index] == 0x22 {
                index += 1
                while index < count && bytes[index] != 0x22 {
                    if bytes[index] == 0x5C && index + 1 < count { index += 1 }
                    valueBytes.append(bytes[index])
                    index += 1
                }
                index += 1
            } else {
                while index < count && bytes[index] != 0x3B {
                    valueBytes.append(bytes[index])
                    index += 1
                }
                while let last = valueBytes.last, last == 0x20 || last == 0x09 { valueBytes.removeLast() }
            }
            guard !name.isEmpty else { continue }
            let paramValue = String(decoding: valueBytes, as: UTF8.self)

            if let star = name.firstIndex(of: "*") {
                let baseName = String(name[..<star])
                let suffix = name[name.index(after: star)...]
                let isExtended = suffix.isEmpty || suffix.hasSuffix("*")
                let sequence = Int(suffix.trimmingCharacters(in: CharacterSet(charactersIn: "*"))) ?? 0
                extended[baseName, default: []].append((sequence, isExtended, paramValue))
            } else if plain[name] == nil {
                plain[name] = EncodedWords.decode(paramValue)
            }
        }

        for (name, pieces) in extended {
            let ordered = pieces.sorted { $0.0 < $1.0 }
            var charset: String?
            var collected = [UInt8]()
            for (position, piece) in ordered.enumerated() {
                var text = piece.2
                if piece.1 {
                    if position == 0 {
                        let parts = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if parts.count == 3 {
                            charset = String(parts[0])
                            text = String(parts[2])
                        }
                    }
                    collected.append(contentsOf: HeaderValue.percentDecode(text))
                } else {
                    collected.append(contentsOf: Array(text.utf8))
                }
            }
            plain[name] = TextDecoding.string(collected, charset: charset)
        }
        params = plain
    }

    private static func percentDecode(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25, index + 2 < bytes.count,
               let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                output.append(value)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }
}

// MARK: - MIME tree

nonisolated final class MIMEPart: @unchecked Sendable {
    let headers: MIMEHeaders
    let contentType: HeaderValue
    let disposition: HeaderValue
    let body: ByteSpan
    let children: [MIMEPart]

    private static let maxDepth = 16
    private static let maxParts = 5000

    init(span: ByteSpan, headersStart: Int = 0, depth: Int = 0) {
        let parsed = MIMEHeaders.parse(span, from: headersStart)
        headers = parsed.headers
        contentType = HeaderValue(parsed.headers["content-type"])
        disposition = HeaderValue(parsed.headers["content-disposition"])
        body = span.slice(parsed.bodyStart, span.count)

        if contentType.value.hasPrefix("multipart/"), depth < MIMEPart.maxDepth,
           let boundary = contentType.params["boundary"], !boundary.isEmpty {
            children = MIMEPart.split(body, boundary: boundary).map { MIMEPart(span: $0, depth: depth + 1) }
        } else {
            children = []
        }
    }

    var mimeType: String { contentType.value.isEmpty ? "text/plain" : contentType.value }
    var isMultipart: Bool { !children.isEmpty }
    var charset: String? { contentType.params["charset"] }

    var transferEncoding: String {
        (headers["content-transfer-encoding"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    var filename: String? {
        let name = disposition.params["filename"] ?? contentType.params["name"]
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var contentID: String? {
        guard let raw = headers["content-id"] else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        return trimmed.isEmpty ? nil : trimmed
    }

    func decodedData() -> Data {
        switch transferEncoding {
        case "base64":
            return TransferDecoding.base64(body.buffer)
        case "quoted-printable":
            return Data(TransferDecoding.quotedPrintable(body.buffer))
        default:
            return body.data()
        }
    }

    func decodedText() -> String {
        switch transferEncoding {
        case "base64", "quoted-printable":
            return TextDecoding.string(decodedData(), charset: charset)
        default:
            return TextDecoding.string(body.buffer, charset: charset)
        }
    }

    /// Splits a multipart body into its parts.
    private static func split(_ body: ByteSpan, boundary: String) -> [ByteSpan] {
        let delimiter = Array("--".utf8) + Array(boundary.utf8)
        var parts: [ByteSpan] = []
        var searchFrom = 0
        var partStart: Int?

        while let found = body.find(delimiter, from: searchFrom) {
            guard found == 0 || body[found - 1] == 0x0A else {
                searchFrom = found + 1
                continue
            }
            var cursor = found + delimiter.count
            var isClosing = false
            if body.hasPrefix([0x2D, 0x2D], at: cursor) {
                isClosing = true
                cursor += 2
            }
            let (contentEnd, next) = body.lineEnd(from: cursor)
            var restIsBlank = true
            var probe = cursor
            while probe < contentEnd {
                if body[probe] != 0x20 && body[probe] != 0x09 {
                    restIsBlank = false
                    break
                }
                probe += 1
            }
            guard restIsBlank else {
                // A longer boundary that merely starts with ours.
                searchFrom = found + 1
                continue
            }

            if let start = partStart {
                var end = found
                if end > start && body[end - 1] == 0x0A {
                    end -= 1
                    if end > start && body[end - 1] == 0x0D { end -= 1 }
                }
                parts.append(body.slice(start, max(start, end)))
            }
            if isClosing || parts.count >= maxParts {
                partStart = nil
                break
            }
            partStart = next
            searchFrom = next
        }

        // Missing closing delimiter: the last part runs to the end.
        if let start = partStart, start < body.count {
            parts.append(body.slice(start, body.count))
        }
        return parts
    }
}

// MARK: - Choosing what to display

nonisolated struct MessageContent {
    /// text/plain and text/html parts to show, in order.
    var bodies: [MIMEPart] = []
    var attachments: [MIMEPart] = []
    var inlineImages: [MIMEPart] = []

    init() {}

    init(root: MIMEPart, preferHTML: Bool) {
        collect(root, parentIsRelated: false, preferHTML: preferHTML)
    }

    private mutating func merge(_ other: MessageContent) {
        bodies += other.bodies
        attachments += other.attachments
        inlineImages += other.inlineImages
    }

    private mutating func collect(_ part: MIMEPart, parentIsRelated: Bool, preferHTML: Bool) {
        if part.isMultipart {
            let subtype = part.mimeType.dropFirst("multipart/".count)
            switch subtype {
            case "alternative":
                let candidates = part.children.map { child -> MessageContent in
                    var content = MessageContent()
                    content.collect(child, parentIsRelated: false, preferHTML: preferHTML)
                    return content
                }
                func lastIndex(html: Bool) -> Int? {
                    candidates.lastIndex { candidate in
                        candidate.bodies.contains { ($0.mimeType == "text/html") == html }
                    }
                }
                let chosen = (preferHTML ? lastIndex(html: true) ?? lastIndex(html: false)
                                         : lastIndex(html: false) ?? lastIndex(html: true))
                    ?? candidates.firstIndex { !$0.bodies.isEmpty }
                for (index, candidate) in candidates.enumerated() {
                    if index == chosen {
                        merge(candidate)
                    } else {
                        // e.g. a calendar invite offered as an alternative
                        attachments += candidate.attachments
                    }
                }
            case "related":
                for (index, child) in part.children.enumerated() {
                    collect(child, parentIsRelated: index > 0, preferHTML: preferHTML)
                }
            default:
                for child in part.children {
                    collect(child, parentIsRelated: false, preferHTML: preferHTML)
                }
            }
            return
        }

        let type = part.mimeType
        let dispositionType = part.disposition.value
        let isBodyText = type == "text/plain" || type == "text/html"

        if isBodyText && dispositionType != "attachment" && (part.filename == nil || dispositionType == "inline") {
            bodies.append(part)
        } else if type.hasPrefix("image/") && part.contentID != nil && dispositionType != "attachment"
                    && (parentIsRelated || dispositionType == "inline") {
            inlineImages.append(part)
        } else if type.hasPrefix("multipart/") {
            // Multipart without a usable boundary: show whatever is there as text.
            bodies.append(part)
        } else {
            attachments.append(part)
        }
    }

    /// Display names for the attachments, generating names for unnamed parts.
    func attachmentNames() -> [String] {
        attachments.enumerated().map { MessageContent.name(for: $1, position: $0 + 1) }
    }

    static func name(for part: MIMEPart, position: Int) -> String {
        if let filename = part.filename { return filename }
        let ext: String
        switch part.mimeType {
        case "application/pdf": ext = "pdf"
        case "image/png": ext = "png"
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "text/calendar": ext = "ics"
        case "text/plain": ext = "txt"
        case "text/html": ext = "html"
        case "text/csv": ext = "csv"
        case "message/rfc822": ext = "eml"
        default: ext = "bin"
        }
        return "attachment-\(position).\(ext)"
    }
}

// MARK: - Dates

nonisolated enum MailDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let zones: [String: Int] = [
        "ut": 0, "utc": 0, "gmt": 0, "z": 0,
        "est": -300, "edt": -240, "cst": -360, "cdt": -300,
        "mst": -420, "mdt": -360, "pst": -480, "pdt": -420
    ]

    /// Parses RFC 2822 style dates ("Mon, 1 Jan 2024 10:00:00 +0000") plus a
    /// few common variations, without the cost of DateFormatter.
    static func parse(_ input: String) -> Date? {
        var text = Substring(input)
        // Strip trailing comments such as "(UTC)".
        while let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") {
            text = text[..<open] + " " + text[text.index(after: close)...]
        }

        var day: Int?
        var month: Int?
        var year: Int?
        var hour = 0, minute = 0, second = 0
        var offsetMinutes = 0

        for token in text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }) {
            if token.contains(":") {
                let pieces = token.split(separator: ":")
                guard pieces.count >= 2, let h = Int(pieces[0]), let m = Int(pieces[1]) else { continue }
                hour = h
                minute = m
                if pieces.count > 2 { second = Int(pieces[2].prefix(2)) ?? 0 }
            } else if (token.first == "+" || token.first == "-"), token.count == 5, let value = Int(token.dropFirst()) {
                let magnitude = (value / 100) * 60 + value % 100
                offsetMinutes = token.first == "-" ? -magnitude : magnitude
            } else if let number = Int(token) {
                if token.count >= 3 || number > 31 {
                    year = number
                } else if day == nil {
                    day = number
                } else {
                    year = number < 50 ? 2000 + number : 1900 + number
                }
            } else if token.count == 10, token.filter({ $0 == "-" }).count == 2 {
                // yyyy-MM-dd
                let pieces = token.split(separator: "-")
                if pieces.count == 3, let y = Int(pieces[0]), let m = Int(pieces[1]), let d = Int(pieces[2]) {
                    year = y
                    month = m
                    day = d
                }
            } else {
                let lower = token.lowercased()
                if let zone = zones[lower] {
                    offsetMinutes = zone
                } else if month == nil, lower.count >= 3,
                          let monthIndex = months.firstIndex(of: String(lower.prefix(3))) {
                    // Weekday names never collide with month prefixes.
                    month = monthIndex + 1
                }
            }
        }

        guard let d = day, let m = month, let y = year,
              (1...31).contains(d), (1...12).contains(m), (1900...2200).contains(y),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else {
            return nil
        }

        // Days from civil (Howard Hinnant's algorithm).
        let adjustedYear = m <= 2 ? y - 1 : y
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146097 + dayOfEra - 719468

        let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offsetMinutes * 60
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
