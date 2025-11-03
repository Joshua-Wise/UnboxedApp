//
//  ConversionHistory.swift
//  Unboxed
//
//  Conversion history tracking
//

import Foundation
import Combine

struct ConversionHistoryItem: Identifiable, Codable {
    let id: UUID
    let date: Date
    let mboxFiles: [String] // File names
    let status: ConversionStatus
    let totalEmails: Int
    let skippedEmails: Int
    let outputPath: String
    let outputType: OutputType
    let duration: TimeInterval // in seconds

    enum ConversionStatus: String, Codable {
        case success = "Success"
        case failed = "Failed"
        case cancelled = "Cancelled"

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .cancelled: return "stop.circle.fill"
            }
        }

        var color: String {
            switch self {
            case .success: return "green"
            case .failed: return "red"
            case .cancelled: return "orange"
            }
        }
    }

    enum OutputType: String, Codable {
        case singlePDF = "Single PDF"
        case separatePDFs = "Separate PDFs (ZIP)"
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    init(id: UUID = UUID(), date: Date, mboxFiles: [String], status: ConversionStatus, totalEmails: Int, skippedEmails: Int, outputPath: String, outputType: OutputType, duration: TimeInterval) {
        self.id = id
        self.date = date
        self.mboxFiles = mboxFiles
        self.status = status
        self.totalEmails = totalEmails
        self.skippedEmails = skippedEmails
        self.outputPath = outputPath
        self.outputType = outputType
        self.duration = duration
    }
}

class ConversionHistoryManager: ObservableObject {
    @Published var items: [ConversionHistoryItem] = []

    private let userDefaultsKey = "conversionHistory"
    private let maxItems = 100 // Keep last 100 conversions

    init() {
        loadHistory()
    }

    func addItem(_ item: ConversionHistoryItem) {
        items.insert(item, at: 0) // Add to beginning

        // Trim to max items
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }

        saveHistory()
    }

    func clearHistory() {
        items.removeAll()
        saveHistory()
    }

    func removeItem(_ item: ConversionHistoryItem) {
        items.removeAll { $0.id == item.id }
        saveHistory()
    }

    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([ConversionHistoryItem].self, from: data) {
            items = decoded
        }
    }
}
