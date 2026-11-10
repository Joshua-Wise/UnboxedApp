//
//  ConversionViewModel.swift
//  Unboxed
//
//  Owns the state of a conversion and runs the pipeline off the main thread.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Carries a value that is handed from a background task to the main actor
/// exactly once.
nonisolated struct UncheckedTransfer<Value>: @unchecked Sendable {
    let value: Value
}

@MainActor
final class ConversionViewModel: ObservableObject {
    // Files
    @Published var selectedFiles: [URL] = []

    // Progress
    @Published var isProcessing = false
    @Published var isCancelling = false
    @Published var progress: Double = 0.0
    @Published var statusMessage = ""

    // Results
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var showSuccess = false
    @Published var successMessage = ""
    @Published var outputURL: URL?

    // Preview & selection
    @Published var showEmailPreview = false
    @Published var emails: [EmailSummary] = []
    @Published var selectedIDs: Set<Int> = []
    @Published var searchText = ""

    /// The opened MBOX files. Kept alive while their emails are in use.
    private(set) var mappedFiles: [MappedFile] = []

    private var skippedCount = 0
    private var cancelFlag = CancelFlag()
    private var startTime: Date?
    /// Incremented for every run so late progress updates from a finished run are ignored.
    private var generation = 0

    nonisolated static func isMBOX(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mbox" || ext == "mbx"
    }

    // MARK: - Files

    func addFiles(_ urls: [URL]) {
        guard !isProcessing else { return }
        for url in urls where !selectedFiles.contains(url) {
            selectedFiles.append(url)
        }
    }

    func removeFile(_ url: URL) {
        selectedFiles.removeAll { $0 == url }
    }

    func reset() {
        cancelFlag.cancel()
        generation += 1
        selectedFiles.removeAll()
        isProcessing = false
        isCancelling = false
        progress = 0.0
        statusMessage = ""
        outputURL = nil
        showEmailPreview = false
        emails.removeAll()
        selectedIDs.removeAll()
        mappedFiles.removeAll()
        searchText = ""
        skippedCount = 0
    }

    func cancel() {
        guard isProcessing else { return }
        isCancelling = true
        statusMessage = "Cancelling…"
        cancelFlag.cancel()
    }

    // MARK: - Progress plumbing

    private func beginRun(status: String) -> (reporter: ProgressReporter, cancel: CancelFlag) {
        generation += 1
        let run = generation
        let cancel = CancelFlag()
        cancelFlag = cancel
        isProcessing = true
        isCancelling = false
        progress = 0.0
        statusMessage = status

        let reporter = ProgressReporter { [weak self] fraction, message in
            Task { @MainActor [weak self] in
                guard let self,self.generation == run, self.isProcessing, !self.isCancelling else { return }
                self.progress = fraction
                self.statusMessage = message
            }
        }
        return (reporter, cancel)
    }

    private func logHistory(
        _ status: ConversionHistoryItem.ConversionStatus,
        settings: AppSettings,
        history: ConversionHistoryManager,
        totalEmails: Int = 0,
        outputPath: String = "N/A"
    ) {
        history.addItem(ConversionHistoryItem(
            date: Date(),
            mboxFiles: selectedFiles.map { $0.lastPathComponent },
            status: status,
            totalEmails: totalEmails,
            skippedEmails: skippedCount,
            outputPath: outputPath,
            outputType: settings.separatePDFs ? .separatePDFs : .singlePDF,
            duration: Date().timeIntervalSince(startTime ?? Date())
        ))
    }

    // MARK: - Step 1: index the files

    func processFiles(settings: AppSettings, history: ConversionHistoryManager) {
        guard !isProcessing, !selectedFiles.isEmpty else { return }
        let urls = selectedFiles
        let preferHTML = settings.preferHTML
        let (reporter, cancel) = beginRun(status: "Reading MBOX files…")
        let run = generation
        startTime = Date()
        skippedCount = 0

        Task {
            do {
                let indexed = try await Task.detached(priority: .userInitiated) { () throws -> (files: [MappedFile], emails: [EmailSummary], skipped: Int) in
                    var files: [MappedFile] = []
                    var emails: [EmailSummary] = []
                    var skipped = 0
                    for (position, url) in urls.enumerated() {
                        let file = try MappedFile(url: url)
                        let result = try MBOXIndexer.index(
                            file: file,
                            fileIndex: position,
                            firstID: emails.count + 1,
                            preferHTML: preferHTML,
                            progress: { fraction, message in
                                reporter.report((Double(position) + fraction) / Double(urls.count), "\(url.lastPathComponent): \(message)")
                            },
                            cancel: cancel
                        )
                        files.append(file)
                        emails.append(contentsOf: result.emails)
                        skipped += result.skipped
                    }
                    return (files, emails, skipped)
                }.value

                guard generation == run else { return }
                mappedFiles = indexed.files
                emails = indexed.emails
                skippedCount = indexed.skipped
                selectedIDs = Set(indexed.emails.map(\.id))
                searchText = ""
                isProcessing = false

                if settings.showEmailPreview {
                    showEmailPreview = true
                } else {
                    convertSelected(settings: settings, history: history)
                }
            } catch {
                guard generation == run else { return }
                isProcessing = false
                isCancelling = false
                if case MBOXError.cancelled = error {
                    logHistory(.cancelled, settings: settings, history: history)
                } else {
                    errorMessage = error.localizedDescription
                    showError = true
                    logHistory(.failed, settings: settings, history: history, outputPath: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Step 2: generate PDFs

    func convertSelected(settings: AppSettings, history: ConversionHistoryManager) {
        guard !isProcessing else { return }
        let chosen = emails.filter { selectedIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }

        let options = settings.options
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        let baseName = selectedFiles.count == 1 ? selectedFiles[0].deletingPathExtension().lastPathComponent : "emails"
        if options.separatePDFs {
            savePanel.message = "Choose location for ZIP file"
            savePanel.allowedContentTypes = [.zip]
            savePanel.nameFieldStringValue = "\(baseName).zip"
        } else {
            savePanel.message = "Choose location for PDF"
            savePanel.allowedContentTypes = [.pdf]
            savePanel.nameFieldStringValue = "\(baseName).pdf"
        }
        guard savePanel.runModal() == .OK, let destination = savePanel.url else { return }

        let files = mappedFiles
        let (reporter, cancel) = beginRun(status: "Generating PDFs…")
        let run = generation
        if startTime == nil { startTime = Date() }

        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try ConversionEngine.convert(
                        emails: chosen,
                        files: files,
                        options: options,
                        outputURL: destination,
                        progress: reporter,
                        cancel: cancel
                    )
                }.value

                guard generation == run else { return }
                progress = 1.0
                isProcessing = false

                var warnings = outcome.warnings
                if let archive = outcome.unsavedAttachmentsArchive {
                    if let warning = saveAttachmentsArchive(archive, suggestedName: destination.deletingPathExtension().lastPathComponent) {
                        warnings.append(warning)
                    }
                }

                var message: String
                if options.separatePDFs {
                    message = "Successfully converted \(chosen.count) email(s) to \(outcome.pdfCount) PDF file(s)"
                } else {
                    message = "Successfully converted \(chosen.count) email(s) to a \(outcome.pageCount)-page PDF"
                }
                if skippedCount > 0 {
                    message += "\n\n⚠️ Skipped \(skippedCount) empty or malformed message(s) while reading"
                }
                if !outcome.failures.isEmpty {
                    message += "\n\n⚠️ \(outcome.failures.count) email(s) could not be converted:\n"
                    message += outcome.failures.prefix(5).joined(separator: "\n")
                    if outcome.failures.count > 5 { message += "\n…and \(outcome.failures.count - 5) more" }
                }
                for warning in warnings {
                    message += "\n\n⚠️ \(warning)"
                }

                successMessage = message
                outputURL = destination
                showSuccess = true
                logHistory(.success, settings: settings, history: history, totalEmails: chosen.count, outputPath: destination.path)
                startTime = nil
            } catch {
                guard generation == run else { return }
                isProcessing = false
                isCancelling = false
                if case ConversionError.cancelled = error {
                    logHistory(.cancelled, settings: settings, history: history)
                } else {
                    errorMessage = error.localizedDescription
                    showError = true
                    logHistory(.failed, settings: settings, history: history, outputPath: error.localizedDescription)
                }
                startTime = nil
            }
        }
    }

    /// Asks where to put an attachments archive that could not be written
    /// next to the PDF. Returns a warning if it was not saved.
    private func saveAttachmentsArchive(_ archive: URL, suggestedName: String) -> String? {
        defer { try? FileManager.default.removeItem(at: archive) }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.message = "Choose location for the attachments archive"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(suggestedName).attachments.zip"
        guard panel.runModal() == .OK, let destination = panel.url else {
            return "The attachments archive was not saved"
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: archive, to: destination)
            return nil
        } catch {
            return "The attachments archive could not be saved: \(error.localizedDescription)"
        }
    }
}
