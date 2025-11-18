//
//  AttachmentHandler.swift
//  Unboxed
//
//  Attachment extraction and handling utility
//

import Foundation

class AttachmentHandler {
    /// Extract attachments from a raw email body
    static func extractAttachments(rawBody: String, headers: [String: String]) -> [EmailAttachment] {
        let contentType = headers["content-type"] ?? ""

        // Only process multipart messages
        guard contentType.lowercased().contains("multipart") else {
            return []
        }

        // Extract boundary from Content-Type header
        guard let boundaryRange = contentType.range(of: "boundary=") else {
            return []
        }

        let boundaryStart = boundaryRange.upperBound
        var boundary = String(contentType[boundaryStart...])

        // Remove quotes if present
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
            boundary = String(boundary.dropFirst().dropLast())
        }

        // Remove any trailing parameters
        if let semicolonIndex = boundary.firstIndex(of: ";") {
            boundary = String(boundary[..<semicolonIndex])
        }
        boundary = boundary.trimmingCharacters(in: .whitespacesAndNewlines)

        // Split by boundary
        let parts = rawBody.components(separatedBy: "--\(boundary)")

        var attachments: [EmailAttachment] = []

        // Process each part
        for part in parts {
            guard !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard !part.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("--") else { continue }

            if let attachment = extractAttachmentFromPart(part) {
                attachments.append(attachment)
            }
        }

        return attachments
    }

    /// Extract an attachment from a single MIME part
    private static func extractAttachmentFromPart(_ part: String) -> EmailAttachment? {
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

        let contentType = partHeaders["content-type"] ?? ""
        let contentDisposition = partHeaders["content-disposition"] ?? ""
        let encoding = partHeaders["content-transfer-encoding"] ?? ""

        // Check if this is an attachment
        let isAttachment = contentDisposition.lowercased().contains("attachment") ||
                          contentDisposition.lowercased().contains("filename=")

        // Skip text/plain and text/html parts unless they're explicitly marked as attachments
        if !isAttachment {
            if contentType.contains("text/plain") || contentType.contains("text/html") {
                return nil
            }
        }

        // Extract filename
        var filename = extractFilename(from: contentDisposition) ?? extractFilename(from: contentType)

        // If no filename found but has content type, skip (likely inline content)
        guard let foundFilename = filename else {
            return nil
        }

        filename = foundFilename

        // Extract MIME type
        var mimeType = contentType
        if let semicolonIndex = mimeType.firstIndex(of: ";") {
            mimeType = String(mimeType[..<semicolonIndex])
        }
        mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)

        // Default to application/octet-stream if no type specified
        if mimeType.isEmpty {
            mimeType = "application/octet-stream"
        }

        // Extract and decode body
        let partBodyLines = Array(partLines[partBodyStartIndex...])
        let partBody = partBodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        guard let decodedData = decodeAttachmentBody(partBody, encoding: encoding) else {
            return nil
        }

        return EmailAttachment(filename: filename, mimeType: mimeType, data: decodedData)
    }

    /// Extract filename from Content-Disposition or Content-Type header
    private static func extractFilename(from header: String) -> String? {
        // Try to find filename= or filename*=
        let patterns = ["filename\\*?=\"?([^\";\n]+)\"?", "filename\\*?=([^;\n]+)"]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
               let range = Range(match.range(at: 1), in: header) {
                var filename = String(header[range])

                // Remove quotes
                filename = filename.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

                // Handle RFC 2231 encoding (filename*=utf-8''example.pdf)
                if filename.contains("''") {
                    let components = filename.components(separatedBy: "''")
                    if components.count > 1 {
                        filename = components[1]
                        // URL decode
                        filename = filename.removingPercentEncoding ?? filename
                    }
                }

                return filename.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    /// Decode attachment body based on encoding
    private static func decodeAttachmentBody(_ body: String, encoding: String) -> Data? {
        let normalizedEncoding = encoding.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        switch normalizedEncoding {
        case "base64":
            let cleanedBody = body.replacingOccurrences(of: "\n", with: "")
                                  .replacingOccurrences(of: "\r", with: "")
                                  .replacingOccurrences(of: " ", with: "")
            return Data(base64Encoded: cleanedBody)

        case "quoted-printable":
            let decoded = decodeQuotedPrintable(body)
            return decoded.data(using: .utf8)

        default:
            // No encoding or unknown encoding, treat as plain data
            return body.data(using: .utf8)
        }
    }

    /// Decode quoted-printable encoded text
    private static func decodeQuotedPrintable(_ text: String) -> String {
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
}
