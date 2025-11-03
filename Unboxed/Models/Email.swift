//
//  Email.swift
//  Unboxed
//
//  Email data model
//

import Foundation

struct Email: Identifiable, Codable {
    let id = UUID()
    var index: Int
    var subject: String
    var from: String
    var to: String
    var cc: String?
    var date: Date?
    var dateString: String
    var body: String
    var attachments: [String]
    var sourceFile: String

    enum CodingKeys: String, CodingKey {
        case index, subject, from, to, cc, date, dateString, body, attachments, sourceFile
    }
}

extension Email {
    var formattedDate: String {
        guard let date = date else { return dateString }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    var shortDate: String {
        guard let date = date else {
            // Try to extract date from dateString
            if dateString.count >= 10 {
                return String(dateString.prefix(10))
            }
            return dateString
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    var senderName: String {
        // Extract name or email from "Name <email@example.com>" format
        if from.contains("<") {
            if let name = from.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                return name
            }
            // Extract email if name is empty
            if let email = from.components(separatedBy: "<").last?.components(separatedBy: ">").first {
                return email
            }
        }
        return from
    }
}
