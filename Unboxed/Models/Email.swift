//
//  Email.swift
//  Unboxed
//
//  Email data models
//
//  `EmailSummary` is the lightweight record kept for every message in an
//  MBOX file (headers plus the byte range of the message). Bodies and
//  attachments are only decoded on demand into a `ParsedEmail`, so memory use
//  scales with the number of messages rather than the size of the file.
//

import Foundation

nonisolated struct EmailAttachment: Sendable {
    var filename: String
    var mimeType: String
    var charset: String?
    var data: Data

    var isText: Bool { mimeType.hasPrefix("text/") }
    var isImage: Bool { mimeType.hasPrefix("image/") }
    var canMergeIntoPDF: Bool { isText || isImage }
}

nonisolated struct EmailSummary: Identifiable, Sendable {
    /// Unique, 1-based position across every file opened in this session.
    let id: Int
    /// Which opened file the message lives in.
    let fileIndex: Int
    /// Byte range of the message (including its "From " separator line).
    let offset: Int
    let length: Int

    var subject: String
    var from: String
    var to: String
    var cc: String?
    var date: Date?
    var dateString: String
    var attachments: [String]
    var sourceFile: String

    var index: Int { id }
}

nonisolated extension EmailSummary {
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var formattedDate: String {
        guard let date = date else { return dateString }
        return Self.fullDateFormatter.string(from: date)
    }

    var shortDate: String {
        guard let date = date else {
            return dateString.count >= 10 ? String(dateString.prefix(10)) : dateString
        }
        return Self.shortDateFormatter.string(from: date)
    }

    /// Display name from a `Name <email@example.com>` style address.
    var senderName: String {
        guard let open = from.firstIndex(of: "<") else { return from }
        let name = from[..<open]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !name.isEmpty { return name }
        let rest = from[from.index(after: open)...]
        if let close = rest.firstIndex(of: ">") { return String(rest[..<close]) }
        return String(rest)
    }

    /// A placeholder used for the filename preview in Settings.
    static var sample: EmailSummary {
        EmailSummary(
            id: 1, fileIndex: 0, offset: 0, length: 0,
            subject: "Sample Subject",
            from: "sender@example.com",
            to: "recipient@example.com",
            cc: nil,
            date: Date(),
            dateString: "",
            attachments: [],
            sourceFile: "sample"
        )
    }
}

/// One displayable piece of a message body.
nonisolated struct BodySegment: Sendable {
    var isHTML: Bool
    var text: String
}

/// A fully decoded message, produced on demand from an `EmailSummary`.
nonisolated struct ParsedEmail: Sendable {
    var summary: EmailSummary
    var segments: [BodySegment]
    /// Decoded attachments. Empty unless attachment data was requested.
    var attachments: [EmailAttachment]
    /// Images referenced from the HTML body by Content-ID.
    var inlineImages: [String: Data]

    var plainText: String {
        segments.map(\.text).joined(separator: "\n")
    }
}
