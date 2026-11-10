//
//  ConversionEngine.swift
//  Unboxed
//
//  Turns a selection of indexed emails into PDF output.
//
//  All work here is synchronous and runs off the main thread. Emails are
//  decoded, laid out and written across all CPU cores; only one email per
//  core is held in memory at a time.
//

import AppKit

nonisolated struct ConversionOutcome: Sendable {
    var pdfCount = 0
    var pageCount = 0
    /// Descriptions of emails that could not be converted.
    var failures: [String] = []
    var warnings: [String] = []
    /// Attachments archive that could not be written next to the PDF and
    /// still needs a destination chosen by the user.
    var unsavedAttachmentsArchive: URL?
}

nonisolated enum ConversionError: LocalizedError {
    case cancelled
    case nothingGenerated(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Conversion cancelled"
        case .nothingGenerated(let reason):
            return "No PDFs could be generated. \(reason)"
        case .saveFailed(let message):
            return "Failed to save: \(message)"
        }
    }
}

nonisolated enum ConversionEngine {
    static func convert(
        emails: [EmailSummary],
        files: [MappedFile],
        options: ConversionOptions,
        outputURL: URL,
        progress: ProgressReporter,
        cancel: CancelFlag
    ) throws -> ConversionOutcome {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent("Unboxed-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        if options.separatePDFs {
            return try convertSeparate(emails: emails, files: files, options: options, outputURL: outputURL,
                                       workDirectory: workDirectory, progress: progress, cancel: cancel)
        }
        return try convertSingle(emails: emails, files: files, options: options, outputURL: outputURL,
                                 workDirectory: workDirectory, progress: progress, cancel: cancel)
    }

    // MARK: - One PDF per email

    private static func convertSeparate(
        emails: [EmailSummary],
        files: [MappedFile],
        options: ConversionOptions,
        outputURL: URL,
        workDirectory: URL,
        progress: ProgressReporter,
        cancel: CancelFlag
    ) throws -> ConversionOutcome {
        let fileManager = FileManager.default
        let contentDirectory = workDirectory.appendingPathComponent("content", isDirectory: true)
        try fileManager.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        let attachmentsDirectory = contentDirectory.appendingPathComponent("attachments", isDirectory: true)
        if options.bundleNonTextAttachments {
            try fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        }

        let total = emails.count
        let loadOptions = MBOXIndexer.LoadOptions(preferHTML: options.preferHTML, loadAttachmentData: options.needsAttachmentData)
        let state = SharedState()

        DispatchQueue.concurrentPerform(iterations: total) { position in
            if cancel.isCancelled { return }
            autoreleasepool {
                let summary = emails[position]
                let email = MBOXIndexer.load(summary, files: files, options: loadOptions)
                let url = contentDirectory.appendingPathComponent(options.buildFilename(for: summary, index: position + 1))

                let layout = PDFRenderer.layout(email: email, title: summary.subject, mergeAttachments: options.mergeAttachmentsIntoPDF)
                if let context = PDFRenderer.makeContext(url: url, title: summary.subject) {
                    PDFRenderer.draw(layout, in: context)
                    context.closePDF()
                    state.recordSuccess(pages: layout.pageCount)
                } else {
                    state.recordFailure("Email #\(summary.id) (\(summary.subject)): could not create PDF")
                }

                if options.bundleNonTextAttachments {
                    saveAttachments(of: email, mergedIntoPDF: options.mergeAttachmentsIntoPDF, to: attachmentsDirectory, state: state)
                }
            }
            let done = state.advance()
            progress.report(0.95 * Double(done) / Double(total), "Generating PDF \(done) of \(total)…")
        }

        if cancel.isCancelled { throw ConversionError.cancelled }
        var outcome = state.outcome()
        guard outcome.pdfCount > 0 else {
            throw ConversionError.nothingGenerated(outcome.failures.first ?? "")
        }

        if options.bundleNonTextAttachments,
           (try? fileManager.contentsOfDirectory(atPath: attachmentsDirectory.path).isEmpty) ?? true {
            try? fileManager.removeItem(at: attachmentsDirectory)
        }

        progress.report(0.95, "Creating ZIP archive…", force: true)
        let archive = workDirectory.appendingPathComponent("archive.zip")
        try zip(directory: contentDirectory, to: archive)
        if cancel.isCancelled { throw ConversionError.cancelled }
        try install(archive, at: outputURL)

        outcome.warnings += state.warnings()
        return outcome
    }

    // MARK: - Single combined PDF

    private static func convertSingle(
        emails: [EmailSummary],
        files: [MappedFile],
        options: ConversionOptions,
        outputURL: URL,
        workDirectory: URL,
        progress: ProgressReporter,
        cancel: CancelFlag
    ) throws -> ConversionOutcome {
        let fileManager = FileManager.default
        let temporaryPDF = workDirectory.appendingPathComponent("output.pdf")
        let attachmentsDirectory = workDirectory.appendingPathComponent("attachments", isDirectory: true)
        if options.bundleNonTextAttachments {
            try fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        }

        guard let context = PDFRenderer.makeContext(url: temporaryPDF, title: outputURL.deletingPathExtension().lastPathComponent) else {
            throw ConversionError.saveFailed("Could not create the PDF document")
        }

        let total = emails.count
        let loadOptions = MBOXIndexer.LoadOptions(preferHTML: options.preferHTML, loadAttachmentData: options.needsAttachmentData)
        let state = SharedState()

        // Emails are laid out in parallel a chunk at a time, then drawn into
        // the single document in order. This keeps memory bounded and lets
        // the fonts be embedded once for the whole document.
        let chunkSize = max(8, ProcessInfo.processInfo.activeProcessorCount * 4)
        nonisolated(unsafe) let layouts = UnsafeMutablePointer<EmailLayout?>.allocate(capacity: chunkSize)
        layouts.initialize(repeating: nil, count: chunkSize)
        defer {
            layouts.deinitialize(count: chunkSize)
            layouts.deallocate()
        }

        var chunkStart = 0
        while chunkStart < total {
            if cancel.isCancelled { break }
            let count = min(chunkSize, total - chunkStart)
            let base = chunkStart

            DispatchQueue.concurrentPerform(iterations: count) { offset in
                if cancel.isCancelled { return }
                autoreleasepool {
                    let summary = emails[base + offset]
                    let email = MBOXIndexer.load(summary, files: files, options: loadOptions)
                    let title = total > 1 ? "Email \(summary.id): \(summary.subject)" : summary.subject
                    layouts[offset] = PDFRenderer.layout(email: email, title: title, mergeAttachments: options.mergeAttachmentsIntoPDF)
                    if options.bundleNonTextAttachments {
                        saveAttachments(of: email, mergedIntoPDF: options.mergeAttachmentsIntoPDF, to: attachmentsDirectory, state: state)
                    }
                }
            }

            for offset in 0..<count {
                autoreleasepool {
                    if let layout = layouts[offset], !cancel.isCancelled {
                        PDFRenderer.draw(layout, in: context)
                        state.recordSuccess(pages: layout.pageCount)
                    }
                    layouts[offset] = nil
                }
                let done = state.advance()
                progress.report(0.97 * Double(done) / Double(total), "Converting email \(done) of \(total)…")
            }
            chunkStart += count
        }

        context.closePDF()
        if cancel.isCancelled { throw ConversionError.cancelled }

        var outcome = state.outcome()
        guard outcome.pdfCount > 0 else { throw ConversionError.nothingGenerated("") }
        outcome.pdfCount = 1

        progress.report(0.98, "Saving PDF…", force: true)
        try install(temporaryPDF, at: outputURL)

        if options.bundleNonTextAttachments,
           let saved = try? fileManager.contentsOfDirectory(atPath: attachmentsDirectory.path), !saved.isEmpty {
            progress.report(0.99, "Bundling attachments…", force: true)
            let archive = workDirectory.appendingPathComponent("attachments.zip")
            try zip(directory: attachmentsDirectory, to: archive)
            let destination = outputURL.deletingPathExtension().appendingPathExtension("attachments.zip")
            do {
                try install(archive, at: destination)
            } catch {
                // The sandbox only grants access to the file chosen in the save
                // panel; hand the archive back so the user can pick a location.
                let parked = fileManager.temporaryDirectory.appendingPathComponent("Unboxed-attachments-\(UUID().uuidString).zip")
                if (try? fileManager.moveItem(at: archive, to: parked)) != nil {
                    outcome.unsavedAttachmentsArchive = parked
                } else {
                    outcome.warnings.append("The attachments archive could not be saved: \(error.localizedDescription)")
                }
            }
        }

        outcome.warnings += state.warnings()
        return outcome
    }

    // MARK: - Shared bookkeeping

    private final class SharedState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = 0
        private var pdfs = 0
        private var pages = 0
        private var failures: [String] = []
        private var attachmentWarnings = 0
        private var usedAttachmentNames = Set<String>()

        func advance() -> Int {
            lock.lock()
            defer { lock.unlock() }
            completed += 1
            return completed
        }

        func recordSuccess(pages count: Int) {
            lock.lock()
            pdfs += 1
            pages += count
            lock.unlock()
        }

        func recordFailure(_ message: String) {
            lock.lock()
            failures.append(message)
            lock.unlock()
        }

        func recordAttachmentFailure() {
            lock.lock()
            attachmentWarnings += 1
            lock.unlock()
        }

        /// Reserves a filename that has not been used yet.
        func uniqueName(_ proposed: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            var name = proposed
            var counter = 2
            while !usedAttachmentNames.insert(name.lowercased()).inserted {
                let ext = (proposed as NSString).pathExtension
                let stem = (proposed as NSString).deletingPathExtension
                name = ext.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(ext)"
                counter += 1
            }
            return name
        }

        func outcome() -> ConversionOutcome {
            lock.lock()
            defer { lock.unlock() }
            return ConversionOutcome(pdfCount: pdfs, pageCount: pages, failures: failures)
        }

        func warnings() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return attachmentWarnings > 0 ? ["\(attachmentWarnings) attachment(s) could not be saved"] : []
        }
    }

    // MARK: - Attachments

    private static func saveAttachments(of email: ParsedEmail, mergedIntoPDF: Bool, to directory: URL, state: SharedState) {
        for attachment in email.attachments {
            // Attachments merged into the PDF don't need a separate copy.
            if mergedIntoPDF && attachment.canMergeIntoPDF { continue }
            // Never trust a filename from the message as a path.
            let base = (attachment.filename as NSString).lastPathComponent
            let safe = ConversionOptions.sanitizeFilename(base, maxLength: 100)
            let name = state.uniqueName("email_\(email.summary.id)_\(safe)")
            do {
                try attachment.data.write(to: directory.appendingPathComponent(name))
            } catch {
                state.recordAttachmentFailure()
            }
        }
    }

    // MARK: - Files

    /// Zips the contents of `directory` into `archive` using the system zip tool.
    private static func zip(directory: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // PDFs are already compressed, so favour speed.
        process.arguments = ["-q", "-r", "-1", archive.path, "."]
        process.currentDirectoryURL = directory
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ConversionError.saveFailed("Could not start zip: \(error.localizedDescription)")
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ConversionError.saveFailed("ZIP creation failed (status \(process.terminationStatus)) \(message)")
        }
    }

    /// Moves a finished file to its final location, replacing any existing file.
    private static func install(_ source: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw ConversionError.saveFailed("Could not write to \(destination.path): \(error.localizedDescription)")
        }
    }
}
