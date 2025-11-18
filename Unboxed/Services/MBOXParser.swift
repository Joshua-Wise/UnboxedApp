//
//  MBOXParser.swift
//  Unboxed
//
//  MBOX file parsing service
//

import Foundation
import AppKit

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

        print("🗂️ MBOX file parsing debug:")
        print("   File: \(sourceFileName)")
        print("   Total content length: \(content.count)")
        print("   Content preview (first 500 chars): '\(String(content.prefix(500)))'")

        // Split by "From " at the beginning of lines (MBOX format)
        // First, normalize line endings and split into lines
        let normalizedContent = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let allLines = normalizedContent.components(separatedBy: "\n")

        print("   Total lines in MBOX: \(allLines.count)")
        print("   First 10 lines:")
        for (i, line) in allLines.prefix(10).enumerated() {
            print("     \(i): '\(line)'")
        }

        // Find message boundaries (lines starting with "From ")
        var messageStartIndices: [Int] = []
        for (index, line) in allLines.enumerated() {
            if line.hasPrefix("From ") {
                messageStartIndices.append(index)
                print("   Found 'From ' boundary at line \(index): '\(String(line.prefix(100)))...'")
            }
        }

        print("   Found \(messageStartIndices.count) 'From ' boundaries")

        // Extract individual messages
        var messages: [String] = []
        for (i, startIndex) in messageStartIndices.enumerated() {
            let endIndex = (i < messageStartIndices.count - 1) ? messageStartIndices[i + 1] : allLines.count
            let messageLines = Array(allLines[startIndex..<endIndex])
            let message = messageLines.joined(separator: "\n")
            messages.append(message)
        }

        print("   Extracted \(messages.count) complete messages")

        var emails: [Email] = []

        for (index, message) in messages.enumerated() {
            print("   Processing message \(index + 1):")
            print("     Raw message length: \(message.count)")
            print("     Raw message preview: '\(String(message.prefix(200)))'")

            // Skip empty messages
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("     ⚠️ Skipping empty message")
                continue
            }

            // Message already includes "From " line, no need to add it back
            print("     Final message length: \(message.count)")

            if let email = parseEmail(messageText: message, index: index + 1, sourceFile: sourceFileName) {
                emails.append(email)
                print("     ✅ Successfully parsed email")
            } else {
                print("     ❌ Failed to parse email")
            }
        }

        guard !emails.isEmpty else {
            throw ParserError.noEmailsFound
        }

        return emails
    }

    private static func parseEmail(messageText: String, index: Int, sourceFile: String) -> Email? {
        print("🔍 parseEmail called for message #\(index)")
        print("   Message length: \(messageText.count)")

        let lines = messageText.components(separatedBy: "\n")
        print("   Split into \(lines.count) lines")
        print("   First few lines:")
        for (i, line) in lines.prefix(5).enumerated() {
            print("     Line \(i): '\(line)'")
        }

        var headers: [String: String] = [:]
        var bodyStartIndex = 0
        var inHeaders = true

        // Parse headers
        var currentHeader = ""
        var currentValue = ""

        print("📝 Header parsing debug for email #\(index):")
        print("   Total lines: \(lines.count)")

        for (idx, line) in lines.enumerated() {
            if inHeaders {
                // Skip the "From " line (MBOX boundary) - it's not an email header
                if idx == 0 && line.hasPrefix("From ") {
                    print("   → Skipping MBOX boundary line: '\(String(line.prefix(100)))...'")
                    continue
                }

                if line.isEmpty {
                    // End of headers
                    if !currentHeader.isEmpty {
                        headers[currentHeader.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    bodyStartIndex = idx + 1
                    inHeaders = false
                    print("   Found empty line at index \(idx), bodyStartIndex set to \(bodyStartIndex)")
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
                    let isValidHeader = !headerName.contains("=") &&
                                       !headerName.contains("<") &&
                                       !headerName.contains(">") &&
                                       !headerName.contains("3D") &&
                                       headerName.count < 50 &&
                                       !headerName.contains(" ") ||
                                       headerName.lowercased().hasPrefix("received") // Special case for "Received" headers

                    if isValidHeader {
                        // New valid header
                        if !currentHeader.isEmpty {
                            headers[currentHeader.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        currentHeader = headerName
                        currentValue = String(line[line.index(after: colonIndex)...])
                    } else {
                        print("   ⚠️ Skipping invalid header line: '\(String(line.prefix(100)))...'")
                        // This looks like HTML content, we've probably reached the body
                        // End header parsing here
                        if !currentHeader.isEmpty {
                            headers[currentHeader.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        bodyStartIndex = idx
                        inHeaders = false
                        print("   → Detected HTML-like content, ending headers at line \(idx)")
                        break
                    }
                }
            }
        }

        // If we never found an empty line, set bodyStartIndex to end of lines
        if inHeaders {
            print("   ⚠️ Never found empty line to end headers, setting bodyStartIndex to \(lines.count)")
            bodyStartIndex = lines.count
        }

        print("   Final bodyStartIndex: \(bodyStartIndex)")
        print("   Lines available for body: \(max(0, lines.count - bodyStartIndex))")

        // Debug: Print all parsed headers
        print("📧 Parsed headers for email #\(index):")
        for (key, value) in headers {
            print("   \(key): \(value)")
        }

        // Extract body
        let bodyLines = Array(lines[bodyStartIndex...])
        let rawBody = bodyLines.joined(separator: "\n")
        let body = extractReadableBody(rawBody: rawBody, headers: headers)

        // Parse date
        var parsedDate: Date?
        let dateString = headers["date"] ?? ""
        if !dateString.isEmpty {
            parsedDate = parseDate(dateString)
        }

        // Extract attachments
        let attachmentData = AttachmentHandler.extractAttachments(rawBody: rawBody, headers: headers)
        let attachmentNames = attachmentData.map { $0.filename }

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
            attachments: attachmentNames,
            attachmentData: attachmentData.isEmpty ? nil : attachmentData,
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

    private static func extractReadableBody(rawBody: String, headers: [String: String]) -> String {
        let contentType = headers["content-type"] ?? ""
        let encoding = headers["content-transfer-encoding"] ?? ""

        // Debug logging
        print("🔍 Email body extraction debug:")
        print("   Content-Type: '\(contentType)'")
        print("   Content-Transfer-Encoding: '\(encoding)'")
        print("   Raw body length: \(rawBody.count)")
        print("   Raw body preview: '\(String(rawBody.prefix(200)))'")

        // Check if it's a multipart email
        if contentType.lowercased().contains("multipart") {
            print("   → Processing as multipart email")
            return extractMultipartBody(rawBody: rawBody, contentType: contentType)
        }

        // Single part email - check for encoding
        let result = decodeBody(rawBody.trimmingCharacters(in: .whitespacesAndNewlines), encoding: encoding)
        
        // Check if it's HTML and convert to plain text
        if contentType.lowercased().contains("text/html") {
            print("   → Converting single-part HTML to plain text")
            return convertHTMLToPlainText(result)
        }
        
        return result
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
            let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPart.isEmpty else { continue }
            // Skip boundary markers (parts that start with --)
            guard !trimmedPart.hasPrefix("--") else { continue }

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
                var partBody = partBodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Remove any trailing MIME boundary markers
                if let lastBoundaryIndex = partBody.range(of: "--\(boundary)", options: .backwards) {
                    partBody = String(partBody[..<lastBoundaryIndex.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                let encoding = partHeaders["content-transfer-encoding"] ?? ""
                return decodeBody(partBody, encoding: encoding)
            }
        }

        // If no text/plain found, look for text/html
        for part in parts {
            let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPart.isEmpty else { continue }
            // Skip boundary markers (parts that start with --)
            guard !trimmedPart.hasPrefix("--") else { continue }

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
                var partBody = partBodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Remove any trailing MIME boundary markers
                if let lastBoundaryIndex = partBody.range(of: "--\(boundary)", options: .backwards) {
                    partBody = String(partBody[..<lastBoundaryIndex.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                let encoding = partHeaders["content-transfer-encoding"] ?? ""
                let decodedHTML = decodeBody(partBody, encoding: encoding)
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
            // Prepend charset meta tag to ensure proper UTF-8 interpretation
            let htmlWithCharset = "<meta charset=\"utf-8\">\(html)"
            guard let dataWithCharset = htmlWithCharset.data(using: .utf8) else {
                // Fallback to original data if charset addition fails
                return convertHTMLManually(html)
            }
            
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]

            if let attributedString = try? NSAttributedString(data: dataWithCharset, options: options, documentAttributes: nil) {
                let result = attributedString.string
                // Still clean up excessive whitespace from attributed string conversion
                var cleaned = result.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
                cleaned = cleaned.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
                return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return convertHTMLManually(html)
    }
    
    private static func convertHTMLManually(_ html: String) -> String {
        var text = html

        // Remove script and style tags entirely (including their content)
        if let scriptRegex = try? NSRegularExpression(pattern: "<script[^>]*>.*?</script>", options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            text = scriptRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        if let styleRegex = try? NSRegularExpression(pattern: "<style[^>]*>.*?</style>", options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            text = styleRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }

        // Add newlines for block elements before removing tags
        let blockElements = [
            "</p>", "</div>", "</br>", "<br>", "<br/>", "<br />",
            "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>",
            "</li>", "</tr>", "</td>", "</th>", "</blockquote>",
            "</pre>", "</ul>", "</ol>", "</dl>", "</dd>", "</dt>",
            "</header>", "</footer>", "</section>", "</article>", "</nav>",
            "</address>", "</fieldset>", "</form>"
        ]
        for tag in blockElements {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        // Add special formatting for list items
        text = text.replacingOccurrences(of: "<li>", with: "\n• ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<li ", with: "\n• <li ", options: .caseInsensitive)

        // Add spacing for table cells
        text = text.replacingOccurrences(of: "<td>", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<td ", with: " <td ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<th>", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<th ", with: " <th ", options: .caseInsensitive)

        // Remove all remaining HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }

        // Decode comprehensive HTML entities
        let entities: [String: String] = [
            // Common entities
            "&nbsp;": " ",
            "&lt;": "<",
            "&gt;": ">",
            "&amp;": "&",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",

            // Punctuation
            "&ndash;": "–",
            "&mdash;": "—",
            "&hellip;": "…",
            "&lsquo;": "'",
            "&rsquo;": "'",
            "&ldquo;": "\u{201C}",
            "&rdquo;": "\u{201D}",
            "&laquo;": "«",
            "&raquo;": "»",
            "&bull;": "•",
            "&middot;": "·",

            // Symbols
            "&copy;": "©",
            "&reg;": "®",
            "&trade;": "™",
            "&euro;": "€",
            "&pound;": "£",
            "&yen;": "¥",
            "&cent;": "¢",
            "&sect;": "§",
            "&para;": "¶",
            "&deg;": "°",
            "&plusmn;": "±",
            "&times;": "×",
            "&divide;": "÷",
            "&frac12;": "½",
            "&frac14;": "¼",
            "&frac34;": "¾",

            // Arrows
            "&larr;": "←",
            "&uarr;": "↑",
            "&rarr;": "→",
            "&darr;": "↓",
            "&harr;": "↔",

            // Math
            "&ne;": "≠",
            "&le;": "≤",
            "&ge;": "≥",
            "&infin;": "∞",
            "&sum;": "∑",
            "&prod;": "∏",
            "&minus;": "−",

            // Accented characters
            "&Agrave;": "À", "&Aacute;": "Á", "&Acirc;": "Â", "&Atilde;": "Ã", "&Auml;": "Ä", "&Aring;": "Å",
            "&agrave;": "à", "&aacute;": "á", "&acirc;": "â", "&atilde;": "ã", "&auml;": "ä", "&aring;": "å",
            "&Egrave;": "È", "&Eacute;": "É", "&Ecirc;": "Ê", "&Euml;": "Ë",
            "&egrave;": "è", "&eacute;": "é", "&ecirc;": "ê", "&euml;": "ë",
            "&Igrave;": "Ì", "&Iacute;": "Í", "&Icirc;": "Î", "&Iuml;": "Ï",
            "&igrave;": "ì", "&iacute;": "í", "&icirc;": "î", "&iuml;": "ï",
            "&Ograve;": "Ò", "&Oacute;": "Ó", "&Ocirc;": "Ô", "&Otilde;": "Õ", "&Ouml;": "Ö", "&Oslash;": "Ø",
            "&ograve;": "ò", "&oacute;": "ó", "&ocirc;": "ô", "&otilde;": "õ", "&ouml;": "ö", "&oslash;": "ø",
            "&Ugrave;": "Ù", "&Uacute;": "Ú", "&Ucirc;": "Û", "&Uuml;": "Ü",
            "&ugrave;": "ù", "&uacute;": "ú", "&ucirc;": "û", "&uuml;": "ü",
            "&Ccedil;": "Ç", "&ccedil;": "ç",
            "&Ntilde;": "Ñ", "&ntilde;": "ñ",
            "&Yacute;": "Ý", "&yacute;": "ý", "&yuml;": "ÿ",
            "&AElig;": "Æ", "&aelig;": "æ",
            "&OElig;": "Œ", "&oelig;": "œ",
            "&szlig;": "ß",
            "&ETH;": "Ð", "&eth;": "ð",
            "&THORN;": "Þ", "&thorn;": "þ"
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
        text = text.replacingOccurrences(of: " \n", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n ", with: "\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
