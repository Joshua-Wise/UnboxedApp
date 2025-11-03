//
//  PDFGenerator.swift
//  Unboxed
//
//  PDF generation service using PDFKit
//

import Foundation
import PDFKit
import AppKit

// Thread-safe progress tracking
actor ProgressTracker {
    private var completed: Int = 0
    private let total: Int
    private let callback: ((Double, String) async -> Void)?
    private var lastReportedProgress: Int = 0

    init(total: Int, callback: ((Double, String) async -> Void)?) {
        self.total = total
        self.callback = callback
    }

    func increment() async {
        completed += 1

        // Report progress every 10 emails or on completion
        if completed == total || completed - lastReportedProgress >= 10 {
            lastReportedProgress = completed
            let progress = Double(completed) / Double(total)
            await callback?(progress, "Generating PDF \(completed) of \(total)...")
        }
    }

    func getProgress() -> Double {
        return Double(completed) / Double(total)
    }
}

class PDFGenerator {
    enum GeneratorError: LocalizedError {
        case creationFailed
        case saveFailed(String)
        case multipleErrors([Error])

        var errorDescription: String? {
            switch self {
            case .creationFailed:
                return "Failed to create PDF document"
            case .saveFailed(let message):
                return "Failed to save PDF: \(message)"
            case .multipleErrors(let errors):
                return "Multiple errors occurred: \(errors.count) PDFs failed"
            }
        }
    }

    static func generateSinglePDF(emails: [Email], outputURL: URL) async throws {
        let pdfDocument = PDFDocument()

        for (index, email) in emails.enumerated() {
            if let page = await createPage(for: email, pageNumber: index + 1, totalPages: emails.count) {
                pdfDocument.insert(page, at: pdfDocument.pageCount)
            }
        }

        guard pdfDocument.write(to: outputURL) else {
            throw GeneratorError.saveFailed("Could not write to \(outputURL.path)")
        }
    }

    static func generateSeparatePDFs(
        emails: [Email],
        outputDirectory: URL,
        settings: AppSettings,
        progressCallback: ((Double, String) async -> Void)? = nil
    ) async throws -> [URL] {
        // Get concurrency limit from settings (default to 4 if not set)
        let maxConcurrent = settings.maxConcurrentPDFs

        // Pre-compute filenames (on main actor) to avoid calling buildFilename from background tasks
        let filenames = emails.enumerated().map { (index, email) in
            settings.buildFilename(for: email, index: index + 1)
        }

        // Create progress tracker
        let progressTracker = ProgressTracker(total: emails.count, callback: progressCallback)

        // Create a semaphore to limit concurrent tasks
        let semaphore = AsyncSemaphore(maxCount: maxConcurrent)

        // Storage for results and errors using actor
        let resultStore = ResultStore()

        // Use TaskGroup for parallel processing
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, email) in emails.enumerated() {
                // Wait for semaphore before starting new task
                await semaphore.wait()

                let filename = filenames[index]

                group.addTask {
                    defer {
                        Task {
                            await semaphore.signal()
                        }
                    }

                    do {
                        let fileURL = outputDirectory.appendingPathComponent(filename)

                        let pdfDocument = PDFDocument()
                        if let page = await createPage(for: email, pageNumber: 1, totalPages: 1) {
                            pdfDocument.insert(page, at: 0)
                        }

                        guard pdfDocument.write(to: fileURL) else {
                            throw GeneratorError.saveFailed("Could not write to \(fileURL.path)")
                        }

                        // Store result
                        await resultStore.addURL(fileURL)

                        // Update progress
                        await progressTracker.increment()
                    } catch {
                        await resultStore.addError(error)
                        await progressTracker.increment()
                    }
                }
            }

            // Wait for all tasks to complete
            try await group.waitForAll()
        }

        let pdfURLs = await resultStore.urls
        let errors = await resultStore.errors

        // Report completion
        await progressCallback?(1.0, "Generated \(pdfURLs.count) PDFs")

        // If there were errors but some succeeded, throw error with details
        if !errors.isEmpty {
            if pdfURLs.isEmpty {
                // All failed, throw first error
                throw errors.first!
            } else {
                // Some succeeded, some failed
                throw GeneratorError.multipleErrors(errors)
            }
        }

        return pdfURLs
    }

    // Helper for async semaphore (limits concurrent tasks)
    private actor AsyncSemaphore {
        private var count: Int
        private let maxCount: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(maxCount: Int) {
            self.maxCount = maxCount
            self.count = 0
        }

        func wait() async {
            if count < maxCount {
                count += 1
                return
            }

            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func signal() {
            if let waiter = waiters.first {
                waiters.removeFirst()
                waiter.resume()
            } else {
                count -= 1
            }
        }
    }

    // Thread-safe storage for results
    private actor ResultStore {
        private(set) var urls: [URL] = []
        private(set) var errors: [Error] = []

        func addURL(_ url: URL) {
            urls.append(url)
        }

        func addError(_ error: Error) {
            errors.append(error)
        }
    }

    // Custom view for rendering email content to PDF
    private class EmailContentView: NSView {
        private let content: NSAttributedString
        private let contentRect: CGRect

        init(frame: NSRect, content: NSAttributedString, contentRect: CGRect) {
            self.content = content
            self.contentRect = contentRect
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draw(_ dirtyRect: NSRect) {
            // Fill background with white
            NSColor.white.setFill()
            dirtyRect.fill()

            // Draw the attributed string in the content rect
            content.draw(in: contentRect)
        }
    }

    private static func createPage(for email: Email, pageNumber: Int, totalPages: Int) async -> PDFPage? {
        // Create an NSAttributedString for the content
        let content = createAttributedContent(for: email, pageNumber: pageNumber, totalPages: totalPages)

        // Page dimensions (US Letter)
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // 8.5" x 11" at 72 DPI
        let margin: CGFloat = 54 // 0.75" margins
        let contentRect = CGRect(
            x: margin,
            y: margin,
            width: pageRect.width - (2 * margin),
            height: pageRect.height - (2 * margin)
        )

        // NSView operations must run on main thread
        return await MainActor.run {
            // Create a custom view to render the content
            let view = EmailContentView(frame: pageRect, content: content, contentRect: contentRect)

            // Create PDF data using the view
            let pdfData = view.dataWithPDF(inside: pageRect)

            // Create PDFPage from the rendered data
            guard let pdfDoc = PDFDocument(data: pdfData),
                  let pdfPage = pdfDoc.page(at: 0) else {
                return nil
            }

            return pdfPage
        }
    }

    nonisolated private static func createAttributedContent(for email: Email, pageNumber: Int, totalPages: Int) -> NSAttributedString {
        let content = NSMutableAttributedString()

        // Title style
        let titleFont = NSFont.boldSystemFont(ofSize: 16)
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.alignment = .left
        titleParagraph.paragraphSpacing = 12

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.black,
            .paragraphStyle: titleParagraph
        ]

        // Header style
        let headerFont = NSFont.systemFont(ofSize: 10)
        let headerParagraph = NSMutableParagraphStyle()
        headerParagraph.alignment = .left
        headerParagraph.paragraphSpacing = 4

        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: NSColor.darkGray,
            .paragraphStyle: headerParagraph
        ]

        // Body style
        let bodyFont = NSFont.systemFont(ofSize: 10)
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.alignment = .left
        bodyParagraph.paragraphSpacing = 8

        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.black,
            .paragraphStyle: bodyParagraph
        ]

        // Add title
        let title = totalPages > 1 ? "Email \(email.index): \(email.subject)\n\n" : "\(email.subject)\n\n"
        content.append(NSAttributedString(string: title, attributes: titleAttributes))

        // Add metadata
        if !email.from.isEmpty {
            content.append(NSAttributedString(string: "From: \(email.from)\n", attributes: headerAttributes))
        }
        if !email.to.isEmpty {
            content.append(NSAttributedString(string: "To: \(email.to)\n", attributes: headerAttributes))
        }
        if let cc = email.cc, !cc.isEmpty {
            content.append(NSAttributedString(string: "Cc: \(cc)\n", attributes: headerAttributes))
        }
        if !email.dateString.isEmpty {
            content.append(NSAttributedString(string: "Date: \(email.formattedDate)\n", attributes: headerAttributes))
        }
        if !email.attachments.isEmpty {
            let attachmentsStr = email.attachments.joined(separator: ", ")
            content.append(NSAttributedString(string: "Attachments: \(attachmentsStr)\n", attributes: headerAttributes))
        }

        content.append(NSAttributedString(string: "\n", attributes: headerAttributes))

        // Add body
        content.append(NSAttributedString(string: "Message:\n", attributes: headerAttributes))
        let body = email.body.isEmpty ? "(No content)" : email.body
        content.append(NSAttributedString(string: body + "\n", attributes: bodyAttributes))

        return content
    }

    static func createZIPArchive(pdfURLs: [URL], outputURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var error: NSError?

        coordinator.coordinate(writingItemAt: outputURL, options: .forReplacing, error: &error) { url in
            do {
                // Create ZIP using shell command (macOS built-in)
                let directoryURL = pdfURLs.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSTemporaryDirectory())

                // Add files in batches to avoid argument limit (4096)
                let batchSize = 1000
                for (batchIndex, batch) in stride(from: 0, to: pdfURLs.count, by: batchSize).enumerated() {
                    let endIndex = min(batch + batchSize, pdfURLs.count)
                    let batchURLs = Array(pdfURLs[batch..<endIndex])

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")

                    // First batch creates the archive, subsequent batches update it
                    if batchIndex == 0 {
                        process.arguments = ["-j", url.path] + batchURLs.map { $0.path }
                    } else {
                        process.arguments = ["-j", "-u", url.path] + batchURLs.map { $0.path }
                    }

                    process.currentDirectoryURL = directoryURL

                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        throw GeneratorError.saveFailed("ZIP process failed with status \(process.terminationStatus)")
                    }
                }
            } catch {
                print("ZIP creation error: \(error)")
            }
        }

        if let error = error {
            throw GeneratorError.saveFailed(error.localizedDescription)
        }
    }
}
