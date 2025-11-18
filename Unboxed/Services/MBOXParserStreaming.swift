//
//  MBOXParserStreaming.swift
//  Unboxed
//
//  Streaming MBOX file parser for large files
//

import Foundation

class MBOXParserStreaming {
    enum ParserError: LocalizedError {
        case invalidFile
        case noEmailsFound
        case readError(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return "Invalid MBOX file format"
            case .noEmailsFound:
                return "No emails found in MBOX file"
            case .readError(let message):
                return "Error reading file: \(message)"
            case .cancelled:
                return "Parsing cancelled"
            }
        }
    }

    struct SkippedEmail {
        let index: Int
        let reason: String
    }

    struct ParseResult {
        let emails: [Email]
        let skipped: [SkippedEmail]
        let totalProcessed: Int

        var summary: String {
            if skipped.isEmpty {
                return "Successfully parsed \(emails.count) emails"
            } else {
                return "Parsed \(emails.count) emails, skipped \(skipped.count) malformed emails"
            }
        }
    }

    typealias ProgressCallback = (Double, String) async -> Void

    static func parse(
        fileURL: URL,
        progressCallback: @escaping ProgressCallback,
        shouldCancel: @escaping () -> Bool,
        maxBodySizeBytes: Int = 2_000_000
    ) async throws -> ParseResult {
        guard fileURL.pathExtension.lowercased() == "mbox" || fileURL.pathExtension.lowercased() == "mbx" else {
            throw ParserError.invalidFile
        }

        // Get file size for progress calculation
        let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 ?? 0
        let sourceFileName = fileURL.deletingPathExtension().lastPathComponent

        await progressCallback(0.0, "Opening file...")

        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            throw ParserError.readError("Could not open file")
        }

        defer {
            try? fileHandle.close()
        }

        var emails: [Email] = []
        var skippedEmails: [SkippedEmail] = []
        var currentMessage = ""
        var emailIndex = 0
        var bytesRead: Int64 = 0
        let chunkSize = 1024 * 1024 // 1MB chunks

        // Batch processing for parallel email parsing
        var messageBatch: [(String, Int)] = [] // (messageText, index)
        let batchSize = 25 // Process emails in batches for better performance
        let maxConcurrency = min(4, ProcessInfo.processInfo.processorCount) // Limit based on CPU cores

        await progressCallback(0.01, "Reading MBOX file...")

        // Read file in chunks
        var buffer = ""

        while true {
            // Check for cancellation
            if shouldCancel() {
                try? fileHandle.close()
                throw ParserError.cancelled
            }

            // Read chunk
            guard let chunk = try? fileHandle.read(upToCount: chunkSize) else {
                break
            }

            if chunk.isEmpty {
                break
            }

            bytesRead += Int64(chunk.count)

            // Convert to string - try UTF-8, fallback to Latin1
            let chunkString: String
            if let utf8String = String(data: chunk, encoding: .utf8) {
                chunkString = utf8String
            } else if let latin1String = String(data: chunk, encoding: .isoLatin1) {
                chunkString = latin1String
            } else {
                // Last resort: force UTF-8 with replacement characters
                chunkString = String(decoding: chunk, as: UTF8.self)
            }

            buffer += chunkString

            // Process complete messages in buffer
            let lines = buffer.components(separatedBy: "\n")

            // Keep last incomplete line in buffer
            buffer = lines.last ?? ""

            for line in lines.dropLast() {
                // Check for message boundary "From " at start of line
                if line.starts(with: "From ") && !currentMessage.isEmpty {
                    // Add message to batch for parallel processing
                    emailIndex += 1
                    messageBatch.append((currentMessage, emailIndex))

                    // Process batch when it reaches batchSize
                    if messageBatch.count >= batchSize {
                        let (batchEmails, batchSkipped) = await processBatch(
                            messageBatch,
                            sourceFileName: sourceFileName,
                            maxBodySizeBytes: maxBodySizeBytes,
                            maxConcurrency: maxConcurrency
                        )
                        emails.append(contentsOf: batchEmails)
                        skippedEmails.append(contentsOf: batchSkipped)
                        messageBatch.removeAll()

                        // Progress update
                        let progress = Double(bytesRead) / Double(fileSize)
                        await progressCallback(progress * 0.8, "Parsed \(emailIndex) emails...")
                    }

                    // Start new message
                    currentMessage = line + "\n"
                } else {
                    currentMessage += line + "\n"
                }
            }

            // Yield to allow UI updates
            if bytesRead % Int64(chunkSize * 10) == 0 {
                await Task.yield()
            }
        }

        // Process last message
        if !currentMessage.isEmpty {
            emailIndex += 1
            messageBatch.append((currentMessage, emailIndex))
        }

        // Process any remaining messages in the final batch
        if !messageBatch.isEmpty {
            let (batchEmails, batchSkipped) = await processBatch(
                messageBatch,
                sourceFileName: sourceFileName,
                maxBodySizeBytes: maxBodySizeBytes,
                maxConcurrency: maxConcurrency
            )
            emails.append(contentsOf: batchEmails)
            skippedEmails.append(contentsOf: batchSkipped)
        }

        guard !emails.isEmpty else {
            throw ParserError.noEmailsFound
        }

        let result = ParseResult(emails: emails, skipped: skippedEmails, totalProcessed: emailIndex)

        await progressCallback(0.85, result.summary)

        // Print summary to console
        if !skippedEmails.isEmpty {
            print("\n📊 Parsing Summary:")
            print("  ✓ Successfully parsed: \(emails.count) emails")
            print("  ⚠️  Skipped: \(skippedEmails.count) emails")
            print("\nSkipped emails:")
            for skipped in skippedEmails.prefix(10) {
                print("  • Email #\(skipped.index): \(skipped.reason)")
            }
            if skippedEmails.count > 10 {
                print("  ... and \(skippedEmails.count - 10) more")
            }
        }

        return result
    }

    // Process a batch of messages in parallel for better performance
    private static func processBatch(
        _ messageBatch: [(String, Int)],
        sourceFileName: String,
        maxBodySizeBytes: Int,
        maxConcurrency: Int
    ) async -> ([Email], [SkippedEmail]) {
        var emails: [Email] = []
        var skippedEmails: [SkippedEmail] = []

        // Use TaskGroup for parallel email parsing
        await withTaskGroup(of: (Int, ParseEmailResult).self) { group in
            let semaphore = BatchSemaphore(maxCount: maxConcurrency)

            for (messageText, index) in messageBatch {
                await semaphore.wait()

                group.addTask {
                    defer {
                        Task { await semaphore.signal() }
                    }

                    let result = parseEmail(
                        messageText: messageText,
                        index: index,
                        sourceFile: sourceFileName,
                        maxBodySizeBytes: maxBodySizeBytes
                    )
                    return (index, result)
                }
            }

            // Collect results maintaining order
            var results: [(Int, ParseEmailResult)] = []
            for await result in group {
                results.append(result)
            }

            // Sort by index to maintain email order
            results.sort { $0.0 < $1.0 }

            // Process results in order
            for (_, result) in results {
                switch result {
                case .success(let email):
                    emails.append(email)
                case .skipped(let reason):
                    skippedEmails.append(SkippedEmail(index: emails.count + skippedEmails.count + 1, reason: reason))
                }
            }
        }

        return (emails, skippedEmails)
    }

    // Simple semaphore for batch processing
    private actor BatchSemaphore {
        private var count = 0
        private let maxCount: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(maxCount: Int) {
            self.maxCount = maxCount
        }

        func wait() async {
            if count < maxCount {
                count += 1
                return
            }

            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func signal() {
            if let waiter = waiters.first {
                waiters.removeFirst()
                waiter.resume()
            } else {
                count -= 1
            }
        }
    }

    enum ParseEmailResult {
        case success(Email)
        case skipped(String)
    }

    private static func parseEmail(messageText: String, index: Int, sourceFile: String, maxBodySizeBytes: Int) -> ParseEmailResult {
        let lines = messageText.components(separatedBy: "\n")
        var headers: [String: String] = [:]
        var bodyStartIndex = 0
        var inHeaders = true

        // Parse headers (always parse these regardless of size)
        var currentHeader = ""
        var currentValue = ""

        for (idx, line) in lines.enumerated() {
            // Skip extremely long lines that might cause issues
            guard line.count < 1_000_000 else { continue }

            if inHeaders {
                // Skip the "From " line (MBOX boundary) - it's not an email header
                if idx == 0 && line.hasPrefix("From ") {
                    continue
                }

                if line.isEmpty {
                    // End of headers
                    if !currentHeader.isEmpty {
                        headers[currentHeader.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    bodyStartIndex = idx + 1
                    inHeaders = false
                    break
                } else if line.first?.isWhitespace == true {
                    // Continuation of previous header
                    currentValue += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let colonIndex = line.firstIndex(of: ":") {
                    // Check if this looks like a valid email header (not HTML content)
                    let headerName = String(line[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)

                    // Valid email headers should:
                    // 1. Not contain HTML-like content (=, <, >, 3D)
                    // 2. Not be longer than reasonable (avoid HTML fragments)
                    // 3. Not contain spaces (except for some continuation cases)
                    // 4. Have reasonable total line length
                    let isValidHeader = !headerName.contains("=") &&
                                       !headerName.contains("<") &&
                                       !headerName.contains(">") &&
                                       !headerName.contains("3D") &&
                                       headerName.count < 50 &&
                                       line.count < 1000 && // Avoid extremely long corrupted headers
                                       (!headerName.contains(" ") ||
                                        headerName.lowercased().hasPrefix("received")) // Special case for "Received" headers

                    if isValidHeader {
                        // New valid header
                        if !currentHeader.isEmpty {
                            headers[currentHeader.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        currentHeader = headerName
                        if colonIndex < line.endIndex {
                            let valueStart = line.index(after: colonIndex)
                            currentValue = String(line[valueStart...])
                        } else {
                            currentValue = ""
                        }
                    } else {
                        // This looks like HTML content, we've probably reached the body
                        // End header parsing here
                        if !currentHeader.isEmpty {
                            headers[currentHeader.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        bodyStartIndex = idx
                        inHeaders = false
                        break
                    }
                }
            }
        }

        // If we never found an empty line, set bodyStartIndex to end of lines
        if inHeaders {
            bodyStartIndex = lines.count
        }

        // Extract body with user-configurable size limit
        let bodyLines = Array(lines[bodyStartIndex...])
        let rawBodyText = bodyLines.joined(separator: "\n")

        // Extract readable content from MIME email
        let decodedBody = extractReadableBody(rawBody: rawBodyText, headers: headers)

        var body: String

        if decodedBody.count > maxBodySizeBytes {
            body = String(decodedBody.prefix(maxBodySizeBytes))
            let truncatedBytes = decodedBody.count - maxBodySizeBytes
            let truncatedMB = Double(truncatedBytes) / 1_000_000
            body += "\n\n" + String(repeating: "=", count: 50)
            body += "\n[CONTENT TRUNCATED - \(String(format: "%.1f", truncatedMB))MB of content not displayed]"
            body += "\n[Original size: \(String(format: "%.1f", Double(decodedBody.count) / 1_000_000))MB]"
            body += "\n" + String(repeating: "=", count: 50)
        } else {
            body = decodedBody
        }

        body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse date
        var parsedDate: Date?
        let dateString = headers["date"] ?? ""
        if !dateString.isEmpty {
            parsedDate = parseDate(dateString)
        }

        // Create email object with safe header decoding
        let subject = headers["subject"].map { decodeHeader($0) } ?? "(No Subject)"
        let from = headers["from"].map { decodeHeader($0) } ?? ""
        let to = headers["to"].map { decodeHeader($0) } ?? ""
        let cc = headers["cc"].map { decodeHeader($0) }

        let email = Email(
            index: index,
            subject: subject,
            from: from,
            to: to,
            cc: cc,
            date: parsedDate,
            dateString: dateString,
            body: body,
            attachments: [],
            sourceFile: sourceFile
        )

        return .success(email)
    }

    private static func decodeHeader(_ header: String) -> String {
        var decoded = header

        // Decode =?charset?encoding?text?= format
        let pattern = "=\\?([^?]+)\\?([QB])\\?([^?]+)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return decoded
        }

        let matches = regex.matches(in: header, range: NSRange(header.startIndex..., in: header))
        for match in matches.reversed() {
            guard match.numberOfRanges == 4,
                  let encodingRange = Range(match.range(at: 2), in: header),
                  let textRange = Range(match.range(at: 3), in: header),
                  let fullRange = Range(match.range(at: 0), in: header) else {
                continue
            }

            let encoding = String(header[encodingRange]).uppercased()
            let encodedText = String(header[textRange])

            var decodedText = encodedText
            if encoding == "Q" {
                decodedText = decodeQuotedPrintable(encodedText)
            } else if encoding == "B" {
                if let data = Data(base64Encoded: encodedText),
                   let text = String(data: data, encoding: .utf8) {
                    decodedText = text
                }
            }

            decoded = decoded.replacingCharacters(in: fullRange, with: decodedText)
        }

        return decoded
    }

    private static func decodeQuotedPrintable(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "_", with: " ")

        let pattern = "=([0-9A-F]{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return result
        }

        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let hexString = String(result[range].dropFirst())
            if let value = UInt8(hexString, radix: 16) {
                let scalar = UnicodeScalar(value)
                let char = String(Character(scalar))
                result = result.replacingCharacters(in: range, with: char)
            }
        }

        return result
    }

    private static func parseDate(_ dateString: String) -> Date? {
        let formatters = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss z",
            "yyyy-MM-dd HH:mm:ss Z"
        ]

        for format in formatters {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: dateString) {
                return date
            }
        }

        return nil
    }

    private static func extractReadableBody(rawBody: String, headers: [String: String]) -> String {
        let contentType = headers["content-type"] ?? ""
        let encoding = headers["content-transfer-encoding"] ?? ""

        // Check if it's a multipart email
        if contentType.lowercased().contains("multipart") {
            return extractMultipartBody(rawBody: rawBody, contentType: contentType)
        }

        // Single part email - check for encoding
        return decodeBody(rawBody.trimmingCharacters(in: .whitespacesAndNewlines), encoding: encoding)
    }

    private static func extractMultipartBody(rawBody: String, contentType: String) -> String {
        // Extract boundary from Content-Type header
        guard let boundaryRange = contentType.range(of: "boundary=") else {
            return rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let boundaryStart = boundaryRange.upperBound
        var boundary = String(contentType[boundaryStart...])

        // Remove quotes if present
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
            boundary = String(boundary.dropFirst().dropLast())
        }

        // Split by boundary
        let parts = rawBody.components(separatedBy: "--\(boundary)")

        // Look for text/plain or text/html parts
        for part in parts {
            guard !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let partLines = part.components(separatedBy: "\n")
            var partHeaders: [String: String] = [:]
            var partBodyStartIndex = 0

            // Parse part headers
            for (idx, line) in partLines.enumerated() {
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    partBodyStartIndex = idx + 1
                    break
                } else if let colonIndex = line.firstIndex(of: ":") {
                    let headerName = String(line[..<colonIndex]).lowercased()
                    let headerValue = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    partHeaders[headerName] = headerValue
                }
            }

            let partContentType = partHeaders["content-type"] ?? ""

            // Prefer text/plain, fall back to text/html
            if partContentType.contains("text/plain") {
                let partBodyLines = Array(partLines[partBodyStartIndex...])
                let partBody = partBodyLines.joined(separator: "\n")
                let encoding = partHeaders["content-transfer-encoding"] ?? ""
                return decodeBody(partBody.trimmingCharacters(in: .whitespacesAndNewlines), encoding: encoding)
            }
        }

        // If no text/plain found, look for text/html
        for part in parts {
            guard !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let partLines = part.components(separatedBy: "\n")
            var partHeaders: [String: String] = [:]
            var partBodyStartIndex = 0

            for (idx, line) in partLines.enumerated() {
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    partBodyStartIndex = idx + 1
                    break
                } else if let colonIndex = line.firstIndex(of: ":") {
                    let headerName = String(line[..<colonIndex]).lowercased()
                    let headerValue = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    partHeaders[headerName] = headerValue
                }
            }

            let partContentType = partHeaders["content-type"] ?? ""

            if partContentType.contains("text/html") {
                let partBodyLines = Array(partLines[partBodyStartIndex...])
                let partBody = partBodyLines.joined(separator: "\n")
                let encoding = partHeaders["content-transfer-encoding"] ?? ""
                let decodedHTML = decodeBody(partBody.trimmingCharacters(in: .whitespacesAndNewlines), encoding: encoding)
                // Convert HTML to plain text
                return convertHTMLToPlainText(decodedHTML)
            }
        }

        // Fallback to raw body
        return rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeBody(_ body: String, encoding: String) -> String {
        let normalizedEncoding = encoding.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        switch normalizedEncoding {
        case "base64":
            if let data = Data(base64Encoded: body.replacingOccurrences(of: "\n", with: "")),
               let decodedString = String(data: data, encoding: .utf8) {
                return decodedString
            }
            return body

        case "quoted-printable":
            return decodeQuotedPrintableBody(body)

        default:
            return body
        }
    }

    private static func decodeQuotedPrintableBody(_ text: String) -> String {
        var result = text

        // Handle soft line breaks (= at end of line)
        result = result.replacingOccurrences(of: "=\n", with: "")
        result = result.replacingOccurrences(of: "=\r\n", with: "")

        // Decode =XX hex sequences
        let pattern = "=([0-9A-F]{2})"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let hexString = String(result[range].dropFirst()) // Remove "="
                if let value = UInt8(hexString, radix: 16) {
                    let char = String(Character(UnicodeScalar(value)))
                    result = result.replacingCharacters(in: range, with: char)
                }
            }
        }

        return result
    }

    private static func convertHTMLToPlainText(_ html: String) -> String {
        // Try to use NSAttributedString for HTML parsing (macOS native approach)
        if let data = html.data(using: .utf8) {
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]

            if let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
                return attributedString.string
            }
        }

        // Fallback: Manual HTML tag stripping
        var text = html

        // Add newlines for block elements before removing tags
        let blockElements = ["</p>", "</div>", "</br>", "<br>", "<br/>", "<br />", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>", "</li>", "</tr>"]
        for tag in blockElements {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        // Remove all HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }

        // Decode common HTML entities
        let entities: [String: String] = [
            "&nbsp;": " ",
            "&lt;": "<",
            "&gt;": ">",
            "&amp;": "&",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&ndash;": "–",
            "&mdash;": "—",
            "&copy;": "©",
            "&reg;": "®",
            "&trade;": "™"
        ]

        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }

        // Decode numeric HTML entities (&#123; or &#xAB;)
        if let numericRegex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
            let matches = numericRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                if let range = Range(match.range, in: text),
                   let numberRange = Range(match.range(at: 1), in: text),
                   let code = Int(text[numberRange]),
                   let scalar = UnicodeScalar(code) {
                    text.replaceSubrange(range, with: String(Character(scalar)))
                }
            }
        }

        // Decode hex HTML entities (&#xAB;)
        if let hexRegex = try? NSRegularExpression(pattern: "&#x([0-9A-Fa-f]+);", options: []) {
            let matches = hexRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                if let range = Range(match.range, in: text),
                   let hexRange = Range(match.range(at: 1), in: text),
                   let code = Int(text[hexRange], radix: 16),
                   let scalar = UnicodeScalar(code) {
                    text.replaceSubrange(range, with: String(Character(scalar)))
                }
            }
        }

        // Clean up excessive whitespace
        text = text.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
