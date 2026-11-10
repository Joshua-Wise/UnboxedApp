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

    @Published var preferHTML: Bool {
        didSet {
            UserDefaults.standard.set(preferHTML, forKey: "preferHTML")
        }
    }

    init() {
        // Default to the formatted (HTML) version of a message when it has one
        let preferHTMLExists = UserDefaults.standard.object(forKey: "preferHTML") != nil
        self.preferHTML = preferHTMLExists ? UserDefaults.standard.bool(forKey: "preferHTML") : true

        self.separatePDFs = UserDefaults.standard.bool(forKey: "separatePDFs")

        // Default to true if not set
        let previewExists = UserDefaults.standard.object(forKey: "showEmailPreview") != nil
        self.showEmailPreview = previewExists ? UserDefaults.standard.bool(forKey: "showEmailPreview") : true

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

    /// A thread-safe snapshot of the settings for use by the conversion pipeline.
    var options: ConversionOptions {
        ConversionOptions(
            separatePDFs: separatePDFs,
            mergeAttachmentsIntoPDF: mergeAttachmentsIntoPDF,
            bundleNonTextAttachments: bundleNonTextAttachments,
            preferHTML: preferHTML,
            namingComponents: namingComponents
        )
    }

    func buildFilename(for email: EmailSummary, index: Int) -> String {
        options.buildFilename(for: email, index: index)
    }
}

/// Immutable copy of the conversion settings that can be passed to background work.
nonisolated struct ConversionOptions: Sendable {
    var separatePDFs: Bool
    var mergeAttachmentsIntoPDF: Bool
    var bundleNonTextAttachments: Bool
    var preferHTML: Bool
    var namingComponents: [NamingComponent]

    var needsAttachmentData: Bool { mergeAttachmentsIntoPDF || bundleNonTextAttachments }

    func buildFilename(for email: EmailSummary, index: Int) -> String {
        var parts: [String] = [String(format: "%06d", index)]

        for component in namingComponents where component.enabled {
            switch component.type {
            case .subject:
                parts.append(ConversionOptions.sanitizeFilename(email.subject.isEmpty ? "No Subject" : email.subject, maxLength: 50))
            case .date:
                parts.append(ConversionOptions.sanitizeFilename(email.shortDate, maxLength: 20))
            case .sender:
                parts.append(ConversionOptions.sanitizeFilename(email.senderName, maxLength: 30))
            }
        }

        return parts.joined(separator: "_") + ".pdf"
    }

    private static let invalidFilenameCharacters = CharacterSet(charactersIn: "<>:\"/\\|?*")
        .union(.controlCharacters)
        .union(.newlines)

    static func sanitizeFilename(_ text: String, maxLength: Int) -> String {
        var sanitized = text.components(separatedBy: invalidFilenameCharacters).joined(separator: "_")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        if sanitized.count > maxLength {
            sanitized = String(sanitized.prefix(maxLength))
        }
        // Keep each component well inside the 255-byte filename limit.
        while sanitized.utf8.count > maxLength * 2 {
            sanitized.removeLast()
        }
        sanitized = sanitized.trimmingCharacters(in: .whitespaces)

        return sanitized.isEmpty ? "untitled" : sanitized
    }
}

nonisolated struct NamingComponent: Identifiable, Codable, Sendable {
    let id: UUID
    let type: ComponentType
    var enabled: Bool

    init(id: UUID = UUID(), type: ComponentType, enabled: Bool) {
        self.id = id
        self.type = type
        self.enabled = enabled
    }

    enum ComponentType: String, Codable, CaseIterable, Sendable {
        case subject = "Subject"
        case date = "Date"
        case sender = "Sender"
    }
}
