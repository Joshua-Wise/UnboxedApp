//
//  MBOXParser.swift
//  Unboxed
//
//  MBOX file parsing service
//

import Foundation

class MBOXParser {
    enum ParserError: LocalizedError {
        case invalidFile
        case noEmailsFound
        case readError(String)

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return "Invalid MBOX file format"
            case .noEmailsFound:
                return "No emails found in MBOX file"
            case .readError(let message):
                return "Error reading file: \(message)"
            }
        }
    }

    static func parse(fileURL: URL) throws -> [Email] {
        guard fileURL.pathExtension.lowercased() == "mbox" || fileURL.pathExtension.lowercased() == "mbx" else {
            throw ParserError.invalidFile
        }

        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw ParserError.readError("Could not read file content")
        }

        let sourceFileName = fileURL.deletingPathExtension().lastPathComponent

        // Split by "From " at the beginning of lines (MBOX format)
        let messages = content.components(separatedBy: "\nFrom ")
        var emails: [Email] = []

        for (index, message) in messages.enumerated() {
            // Skip empty messages
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            var messageText = message
            // Add back "From " for all except first message
            if index > 0 {
                messageText = "From " + messageText
            }

            if let email = parseEmail(messageText: messageText, index: index + 1, sourceFile: sourceFileName) {
                emails.append(email)
            }
        }

        guard !emails.isEmpty else {
            throw ParserError.noEmailsFound
        }

        return emails
    }

    private static func parseEmail(messageText: String, index: Int, sourceFile: String) -> Email? {
        let lines = messageText.components(separatedBy: "\n")
        var headers: [String: String] = [:]
        var bodyStartIndex = 0
        var inHeaders = true

        // Parse headers
        var currentHeader = ""
        var currentValue = ""

        for (idx, line) in lines.enumerated() {
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
                    currentValue = String(line[line.index(after: colonIndex)...])
                }
            }
        }

        // Extract body
        let bodyLines = Array(lines[bodyStartIndex...])
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse date
        var parsedDate: Date?
        let dateString = headers["date"] ?? ""
        if !dateString.isEmpty {
            parsedDate = parseDate(dateString)
        }

        // Create email object
        return Email(
            index: index,
            subject: decodeHeader(headers["subject"] ?? "(No Subject)"),
            from: decodeHeader(headers["from"] ?? ""),
            to: decodeHeader(headers["to"] ?? ""),
            cc: headers["cc"].map { decodeHeader($0) },
            date: parsedDate,
            dateString: dateString,
            body: body,
            attachments: [], // TODO: Parse attachments if needed
            sourceFile: sourceFile
        )
    }

    private static func decodeHeader(_ header: String) -> String {
        // Simple header decoding (more sophisticated decoding could be added)
        var decoded = header

        // Decode =?charset?encoding?text?= format
        let pattern = "=\\?([^?]+)\\?([QB])\\?([^?]+)\\?="
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let matches = regex.matches(in: header, range: NSRange(header.startIndex..., in: header))
            for match in matches.reversed() {
                guard match.numberOfRanges == 4 else { continue }

                // charsetRange would be: Range(match.range(at: 1), in: header)
                let encodingRange = Range(match.range(at: 2), in: header)!
                let textRange = Range(match.range(at: 3), in: header)!

                let encoding = String(header[encodingRange]).uppercased()
                let encodedText = String(header[textRange])

                var decodedText = encodedText
                if encoding == "Q" {
                    // Quoted-printable
                    decodedText = decodeQuotedPrintable(encodedText)
                } else if encoding == "B" {
                    // Base64
                    if let data = Data(base64Encoded: encodedText),
                       let text = String(data: data, encoding: .utf8) {
                        decodedText = text
                    }
                }

                let fullRange = Range(match.range(at: 0), in: header)!
                decoded = decoded.replacingCharacters(in: fullRange, with: decodedText)
            }
        }

        return decoded
    }

    private static func decodeQuotedPrintable(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "_", with: " ")

        let pattern = "=([0-9A-F]{2})"
        if let regex = try? NSRegularExpression(pattern: pattern) {
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
