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
                    // Process previous message
                    emailIndex += 1

                    if emailIndex % 10 == 0 {
                        let progress = Double(bytesRead) / Double(fileSize)
                        await progressCallback(progress * 0.8, "Parsed \(emailIndex) emails...")
                    }

                    let result = parseEmail(messageText: currentMessage, index: emailIndex, sourceFile: sourceFileName, maxBodySizeBytes: maxBodySizeBytes)
                    switch result {
                    case .success(let email):
                        emails.append(email)
                    case .skipped(let reason):
                        skippedEmails.append(SkippedEmail(index: emailIndex, reason: reason))
                        print("⚠️ Skipped email #\(emailIndex): \(reason)")
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
            let result = parseEmail(messageText: currentMessage, index: emailIndex, sourceFile: sourceFileName, maxBodySizeBytes: maxBodySizeBytes)
            switch result {
            case .success(let email):
                emails.append(email)
            case .skipped(let reason):
                skippedEmails.append(SkippedEmail(index: emailIndex, reason: reason))
                print("⚠️ Skipped email #\(emailIndex): \(reason)")
            }
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
                if line.isEmpty {
                    // End of headers
                    if !currentHeader.isEmpty {
                        headers[currentHeader.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    bodyStartIndex = idx + 1
                    inHeaders = false
                } else if line.first?.isWhitespace == true {
                    // Continuation of previous header
                    currentValue += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let colonIndex = line.firstIndex(of: ":") {
                    // New header
                    if !currentHeader.isEmpty {
                        headers[currentHeader.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    currentHeader = String(line[..<colonIndex])
                    if colonIndex < line.endIndex {
                        let valueStart = line.index(after: colonIndex)
                        currentValue = String(line[valueStart...])
                    } else {
                        currentValue = ""
                    }
                }
            }
        }

        // Extract body with user-configurable size limit
        let bodyLines = Array(lines[bodyStartIndex...])
        let bodyText = bodyLines.joined(separator: "\n")

        var body: String

        if bodyText.count > maxBodySizeBytes {
            body = String(bodyText.prefix(maxBodySizeBytes))
            let truncatedBytes = bodyText.count - maxBodySizeBytes
            let truncatedMB = Double(truncatedBytes) / 1_000_000
            body += "\n\n" + String(repeating: "=", count: 50)
            body += "\n[CONTENT TRUNCATED - \(String(format: "%.1f", truncatedMB))MB of content not displayed]"
            body += "\n[Original size: \(String(format: "%.1f", Double(bodyText.count) / 1_000_000))MB]"
            body += "\n" + String(repeating: "=", count: 50)
        } else {
            body = bodyText
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
}
