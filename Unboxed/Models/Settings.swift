//
//  Settings.swift
//  Unboxed
//
//  Application settings model
//

import Foundation
import Combine

class AppSettings: ObservableObject {
    @Published var separatePDFs: Bool {
        didSet {
            UserDefaults.standard.set(separatePDFs, forKey: "separatePDFs")
        }
    }

    @Published var showEmailPreview: Bool {
        didSet {
            UserDefaults.standard.set(showEmailPreview, forKey: "showEmailPreview")
        }
    }

    @Published var namingComponents: [NamingComponent] {
        didSet {
            if let encoded = try? JSONEncoder().encode(namingComponents) {
                UserDefaults.standard.set(encoded, forKey: "namingComponents")
            }
        }
    }

    @Published var maxEmailBodySizeMB: Int {
        didSet {
            UserDefaults.standard.set(maxEmailBodySizeMB, forKey: "maxEmailBodySizeMB")
        }
    }

    @Published var maxConcurrentPDFs: Int {
        didSet {
            UserDefaults.standard.set(maxConcurrentPDFs, forKey: "maxConcurrentPDFs")
        }
    }

    @Published var mergeAttachmentsIntoPDF: Bool {
        didSet {
            UserDefaults.standard.set(mergeAttachmentsIntoPDF, forKey: "mergeAttachmentsIntoPDF")
        }
    }

    @Published var bundleNonTextAttachments: Bool {
        didSet {
            UserDefaults.standard.set(bundleNonTextAttachments, forKey: "bundleNonTextAttachments")
        }
    }

    init() {
        self.separatePDFs = UserDefaults.standard.bool(forKey: "separatePDFs")

        // Default to true if not set
        let previewExists = UserDefaults.standard.object(forKey: "showEmailPreview") != nil
        self.showEmailPreview = previewExists ? UserDefaults.standard.bool(forKey: "showEmailPreview") : true

        // Default to 2MB if not set
        let savedSize = UserDefaults.standard.integer(forKey: "maxEmailBodySizeMB")
        self.maxEmailBodySizeMB = savedSize > 0 ? savedSize : 2

        // Default to 4 concurrent PDFs if not set
        let savedConcurrency = UserDefaults.standard.integer(forKey: "maxConcurrentPDFs")
        self.maxConcurrentPDFs = savedConcurrency > 0 ? savedConcurrency : 4

        if let data = UserDefaults.standard.data(forKey: "namingComponents"),
           let decoded = try? JSONDecoder().decode([NamingComponent].self, from: data) {
            self.namingComponents = decoded
        } else {
            // Default naming components
            self.namingComponents = [
                NamingComponent(type: .subject, enabled: true),
                NamingComponent(type: .date, enabled: false),
                NamingComponent(type: .sender, enabled: false)
            ]
        }

        // Default to false if not set (opt-in for attachment features)
        self.mergeAttachmentsIntoPDF = UserDefaults.standard.bool(forKey: "mergeAttachmentsIntoPDF")
        self.bundleNonTextAttachments = UserDefaults.standard.bool(forKey: "bundleNonTextAttachments")
    }

    var maxEmailBodySizeBytes: Int {
        return maxEmailBodySizeMB * 1_000_000
    }

    func buildFilename(for email: Email, index: Int) -> String {
        var parts: [String] = [String(format: "%06d", index)]

        for component in namingComponents where component.enabled {
            switch component.type {
            case .subject:
                let sanitized = sanitizeFilename(email.subject.isEmpty ? "No Subject" : email.subject, maxLength: 50)
                parts.append(sanitized)
            case .date:
                let sanitized = sanitizeFilename(email.shortDate, maxLength: 20)
                parts.append(sanitized)
            case .sender:
                let sanitized = sanitizeFilename(email.senderName, maxLength: 30)
                parts.append(sanitized)
            }
        }

        return parts.joined(separator: "_") + ".pdf"
    }

    private func sanitizeFilename(_ text: String, maxLength: Int) -> String {
        var sanitized = text
        // Remove invalid filename characters
        let invalidChars = CharacterSet(charactersIn: "<>:\"/\\|?*")
            .union(.controlCharacters)
        sanitized = sanitized.components(separatedBy: invalidChars).joined(separator: "_")

        // Trim whitespace and dots
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        // Limit length
        if sanitized.count > maxLength {
            sanitized = String(sanitized.prefix(maxLength))
        }

        return sanitized.isEmpty ? "untitled" : sanitized
    }
}

struct NamingComponent: Identifiable, Codable {
    let id: UUID
    let type: ComponentType
    var enabled: Bool

    init(id: UUID = UUID(), type: ComponentType, enabled: Bool) {
        self.id = id
        self.type = type
        self.enabled = enabled
    }

    enum ComponentType: String, Codable, CaseIterable {
        case subject = "Subject"
        case date = "Date"
        case sender = "Sender"
    }
}
