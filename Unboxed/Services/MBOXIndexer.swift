//
//  MBOXIndexer.swift
//  Unboxed
//
//  Memory-mapped MBOX reading.
//
//  Indexing makes one pass over the file to find message boundaries and then
//  summarises the messages in parallel. Message bodies are decoded later, one
//  at a time, straight from the mapped file.
//

import Foundation

// MARK: - Shared helpers

/// Thread-safe cancellation flag shared between the UI and worker threads.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Rate-limits progress callbacks so worker threads can report freely
/// without flooding the main thread.
nonisolated final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: CFAbsoluteTime
    private var lastReport: CFAbsoluteTime = 0
    private let handler: @Sendable (Double, String) -> Void

    init(minimumInterval: CFAbsoluteTime = 0.1, handler: @escaping @Sendable (Double, String) -> Void) {
        self.minimumInterval = minimumInterval
        self.handler = handler
    }

    func report(_ fraction: Double, _ message: @autoclosure () -> String, force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let due = force || now - lastReport >= minimumInterval
        if due { lastReport = now }
        lock.unlock()
        if due { handler(min(max(fraction, 0), 1), message()) }
    }
}

nonisolated enum MBOXError: LocalizedError {
    case invalidFile
    case noEmailsFound(String)
    case readError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "Invalid MBOX file format"
        case .noEmailsFound(let name):
            return "No emails found in \(name)"
        case .readError(let message):
            return "Error reading file: \(message)"
        case .cancelled:
            return "Cancelled"
        }
    }
}

// MARK: - Memory-mapped file

nonisolated final class MappedFile: @unchecked Sendable {
    let url: URL
    let span: ByteSpan
    private let mapping: UnsafeMutableRawPointer?
    private let length: Int

    init(url: URL) throws {
        self.url = url
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw MBOXError.readError("Could not open \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw MBOXError.readError("Could not read the size of \(url.lastPathComponent)")
        }
        length = Int(info.st_size)

        guard length > 0 else {
            mapping = nil
            span = .empty
            return
        }
        guard let pointer = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0), pointer != MAP_FAILED else {
            throw MBOXError.readError("Could not map \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        mapping = pointer
        span = ByteSpan(base: UnsafePointer(pointer.assumingMemoryBound(to: UInt8.self)), count: length)
    }

    deinit {
        if let mapping { munmap(mapping, length) }
    }
}

// MARK: - Indexing

nonisolated struct IndexResult: Sendable {
    var emails: [EmailSummary]
    var skipped: Int
}

nonisolated enum MBOXIndexer {
    private static let fromLine = Array("From ".utf8)
    private static let newlineFromLine = Array("\nFrom ".utf8)

    /// Builds summaries for every message in `file`.
    /// - Parameter firstID: id assigned to the first message found.
    static func index(
        file: MappedFile,
        fileIndex: Int,
        firstID: Int,
        preferHTML: Bool,
        progress: (Double, String) -> Void,
        cancel: CancelFlag
    ) throws -> IndexResult {
        let span = file.span
        let sourceName = file.url.deletingPathExtension().lastPathComponent
        guard !span.isEmpty else { throw MBOXError.noEmailsFound(file.url.lastPathComponent) }

        // Pass 1: message boundaries.
        var starts = try scanBoundaries(span, progress: { fraction in
            progress(fraction * 0.6, "Scanning…")
        }, cancel: cancel)

        if starts.isEmpty {
            // Not an mbox, but possibly a single raw message.
            let probe = MIMEHeaders.parse(span.slice(0, min(span.count, 64 * 1024)))
            guard probe.headers["from"] != nil || probe.headers["subject"] != nil || probe.headers["date"] != nil else {
                throw MBOXError.noEmailsFound(file.url.lastPathComponent)
            }
            starts = [0]
        }

        // Pass 2: summarise in parallel.
        let total = starts.count
        nonisolated(unsafe) let results = UnsafeMutablePointer<EmailSummary?>.allocate(capacity: total)
        results.initialize(repeating: nil, count: total)
        defer {
            results.deinitialize(count: total)
            results.deallocate()
        }

        let batchSize = 256
        let batches = (total + batchSize - 1) / batchSize
        let counterLock = NSLock()
        nonisolated(unsafe) var completed = 0
        let startsCopy = starts

        DispatchQueue.concurrentPerform(iterations: batches) { batch in
            if cancel.isCancelled { return }
            let lower = batch * batchSize
            let upper = min(lower + batchSize, total)
            for position in lower..<upper {
                let start = startsCopy[position]
                let end = position + 1 < total ? startsCopy[position + 1] : span.count
                results[position] = summarise(
                    span.slice(start, end),
                    id: firstID + position,
                    fileIndex: fileIndex,
                    offset: start,
                    sourceName: sourceName,
                    preferHTML: preferHTML
                )
            }
            counterLock.lock()
            completed += upper - lower
            let done = completed
            counterLock.unlock()
            progress(0.6 + 0.4 * Double(done) / Double(total), "Indexed \(done) of \(total) emails…")
        }

        if cancel.isCancelled { throw MBOXError.cancelled }

        var emails: [EmailSummary] = []
        emails.reserveCapacity(total)
        var skipped = 0
        for position in 0..<total {
            if let summary = results[position] {
                emails.append(summary)
            } else {
                skipped += 1
            }
        }
        guard !emails.isEmpty else { throw MBOXError.noEmailsFound(file.url.lastPathComponent) }
        return IndexResult(emails: emails, skipped: skipped)
    }

    /// Finds the offsets of every "From " separator line.
    private static func scanBoundaries(_ span: ByteSpan, progress: (Double) -> Void, cancel: CancelFlag) throws -> [Int] {
        var starts: [Int] = []
        if span.hasPrefix(fromLine) && isSeparator(span, at: 0) { starts.append(0) }

        let window = 32 * 1024 * 1024
        var position = 0
        while position < span.count {
            if cancel.isCancelled { throw MBOXError.cancelled }
            let windowEnd = min(position + window, span.count)
            // Let a match that starts inside this window run past its edge;
            // matches starting at or beyond the edge belong to the next window.
            let searchEnd = min(windowEnd + newlineFromLine.count - 1, span.count)
            var cursor = position
            while let found = span.find(newlineFromLine, from: cursor, to: searchEnd) {
                let lineStart = found + 1
                if isSeparator(span, at: lineStart) { starts.append(lineStart) }
                cursor = lineStart
            }
            position = windowEnd
            progress(Double(position) / Double(span.count))
        }

        return starts
    }

    /// Decides whether a line starting with "From " is really a message
    /// separator rather than body text that happens to start that way.
    private static func isSeparator(_ span: ByteSpan, at start: Int) -> Bool {
        let (contentEnd, next) = span.lineEnd(from: start)
        guard contentEnd - start <= 512 else { return false }

        // A separator carries a timestamp ("... 10:00:00 2024").
        var index = start + fromLine.count
        while index + 4 < contentEnd {
            if span[index + 2] == 0x3A,
               isDigit(span[index]), isDigit(span[index + 1]), isDigit(span[index + 3]), isDigit(span[index + 4]) {
                return true
            }
            index += 1
        }

        // Otherwise require a preceding blank line and a header on the next line.
        let precededByBlank = start == 0
            || (start >= 2 && span[start - 2] == 0x0A)
            || (start >= 3 && span[start - 2] == 0x0D && span[start - 3] == 0x0A)
        guard precededByBlank, next < span.count else { return false }
        let (nextEnd, _) = span.lineEnd(from: next)
        guard let colon = span.index(of: 0x3A, from: next, to: nextEnd), colon > next else { return false }
        for probe in next..<colon where span[probe] <= 0x20 || span[probe] >= 0x7F { return false }
        return true
    }

    @inline(__always) private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// Offset of the RFC 822 headers inside a message span (skips the "From " line).
    private static func headersStart(_ message: ByteSpan) -> Int {
        message.hasPrefix(fromLine) ? message.lineEnd(from: 0).next : 0
    }

    private static func summarise(
        _ message: ByteSpan,
        id: Int,
        fileIndex: Int,
        offset: Int,
        sourceName: String,
        preferHTML: Bool
    ) -> EmailSummary? {
        let root = MIMEPart(span: message, headersStart: headersStart(message))
        if root.headers.isEmpty {
            // Nothing but whitespace between two separators.
            var blank = true
            for index in 0..<min(root.body.count, 4096) where root.body[index] > 0x20 {
                blank = false
                break
            }
            if blank { return nil }
        }

        let headers = root.headers
        let dateString = headers["date"] ?? ""
        let content = MessageContent(root: root, preferHTML: preferHTML)
        let subject = headers["subject"].map { EncodedWords.decode($0) } ?? ""

        return EmailSummary(
            id: id,
            fileIndex: fileIndex,
            offset: offset,
            length: message.count,
            subject: subject.isEmpty ? "(No Subject)" : collapseWhitespace(subject),
            from: collapseWhitespace(EncodedWords.decode(headers["from"] ?? "")),
            to: collapseWhitespace(EncodedWords.decode(headers["to"] ?? "")),
            cc: headers["cc"].map { collapseWhitespace(EncodedWords.decode($0)) },
            date: dateString.isEmpty ? nil : MailDate.parse(dateString),
            dateString: dateString,
            attachments: content.attachmentNames(),
            sourceFile: sourceName
        )
    }

    private static func collapseWhitespace(_ text: String) -> String {
        guard text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) else { return text }
        return text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" }).joined(separator: " ")
    }

    // MARK: - Loading full messages

    struct LoadOptions: Sendable {
        var preferHTML = true
        var loadAttachmentData = false
        /// Bodies longer than this (in UTF-16 units) are truncated before layout.
        var maxBodyLength = 3_000_000
    }

    /// Decodes one message from the mapped file.
    static func load(_ summary: EmailSummary, files: [MappedFile], options: LoadOptions) -> ParsedEmail {
        guard summary.fileIndex < files.count else {
            return ParsedEmail(summary: summary, segments: [], attachments: [], inlineImages: [:])
        }
        let message = files[summary.fileIndex].span.slice(summary.offset, summary.offset + summary.length)
        let root = MIMEPart(span: message, headersStart: headersStart(message))
        let content = MessageContent(root: root, preferHTML: options.preferHTML)

        var segments: [BodySegment] = []
        for part in content.bodies {
            var text = part.decodedText()
            if text.utf16.count > options.maxBodyLength {
                let total = text.utf16.count
                text = String(text.prefix(options.maxBodyLength))
                text += "\n\n[Content truncated: showing the first \(options.maxBodyLength / 1_000_000) million of \(total) characters]"
            }
            guard text.contains(where: { !$0.isWhitespace }) else { continue }
            let isHTML = part.mimeType == "text/html" || looksLikeHTML(text)
            segments.append(BodySegment(isHTML: isHTML, text: text))
        }

        var inlineImages: [String: Data] = [:]
        if segments.contains(where: \.isHTML) {
            let html = segments.filter(\.isHTML).map(\.text)
            // Images sent as regular attachments can also be referenced by cid.
            let candidates = content.inlineImages + content.attachments.filter { $0.mimeType.hasPrefix("image/") }
            for part in candidates {
                guard let contentID = part.contentID, inlineImages[contentID] == nil,
                      html.contains(where: { $0.contains("cid:\(contentID)") }) else { continue }
                inlineImages[contentID] = part.decodedData()
            }
        }

        var attachments: [EmailAttachment] = []
        if options.loadAttachmentData {
            for (position, part) in content.attachments.enumerated() {
                attachments.append(EmailAttachment(
                    filename: MessageContent.name(for: part, position: position + 1),
                    mimeType: part.mimeType == "text/plain" && part.contentType.value.isEmpty ? "application/octet-stream" : part.mimeType,
                    charset: part.charset,
                    data: part.decodedData()
                ))
            }
        }

        return ParsedEmail(summary: summary, segments: segments, attachments: attachments, inlineImages: inlineImages)
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        let head = text.prefix(512).drop(while: { $0.isWhitespace }).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.hasPrefix("<body") || head.hasPrefix("<div")
            || head.hasPrefix("<table") || head.hasPrefix("<head")
    }

    // MARK: - Body search

    /// Returns the ids of the given emails whose decoded body contains `query`.
    static func searchBodies(query: String, in emails: [EmailSummary], files: [MappedFile], cancel: CancelFlag) -> Set<Int> {
        guard !query.isEmpty, !emails.isEmpty else { return [] }
        let lock = NSLock()
        var matches = Set<Int>()
        let batchSize = 64
        let batches = (emails.count + batchSize - 1) / batchSize
        let options = LoadOptions(preferHTML: false, loadAttachmentData: false, maxBodyLength: 1_000_000)

        DispatchQueue.concurrentPerform(iterations: batches) { batch in
            if cancel.isCancelled { return }
            var local: [Int] = []
            let lower = batch * batchSize
            for position in lower..<min(lower + batchSize, emails.count) {
                let parsed = load(emails[position], files: files, options: options)
                if parsed.segments.contains(where: { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                    local.append(emails[position].id)
                }
            }
            guard !local.isEmpty else { return }
            lock.lock()
            matches.formUnion(local)
            lock.unlock()
        }
        return matches
    }
}
