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

    static func generateSinglePDF(emails: [Email], outputURL: URL, settings: AppSettings) async throws {
        let pdfDocument = PDFDocument()

        for (index, email) in emails.enumerated() {
            if let page = await createPage(for: email, pageNumber: index + 1, totalPages: emails.count, settings: settings) {
                pdfDocument.insert(page, at: pdfDocument.pageCount)
            }
        }

        guard pdfDocument.write(to: outputURL) else {
            throw GeneratorError.saveFailed("Could not write to \(outputURL.path)")
        }

        // Handle non-text attachments bundling
        if settings.bundleNonTextAttachments {
            let attachmentsZipURL = outputURL.deletingPathExtension().appendingPathExtension("attachments.zip")
            try saveNonTextAttachments(from: emails, to: attachmentsZipURL)
        }
    }

    static func generateSeparatePDFs(
        emails: [Email],
        outputDirectory: URL,
        settings: AppSettings,
        progressCallback: ((Double, String) async -> Void)? = nil
    ) async throws -> [URL] {
        // Analyze content sizes to adjust concurrency
        let largeEmailCount = emails.filter { $0.body.count > 500_000 }.count
        let hugeEmailCount = emails.filter { $0.body.count > 2_000_000 }.count

        // Reduce concurrency for large content to prevent memory issues
        var adjustedConcurrency = settings.maxConcurrentPDFs
        if hugeEmailCount > 0 {
            adjustedConcurrency = min(2, adjustedConcurrency) // Max 2 for huge emails
            print("📊 Detected \(hugeEmailCount) huge emails (>2MB), reducing concurrency to \(adjustedConcurrency)")
        } else if largeEmailCount > 5 {
            adjustedConcurrency = min(3, adjustedConcurrency) // Max 3 for many large emails
            print("📊 Detected \(largeEmailCount) large emails (>500KB), reducing concurrency to \(adjustedConcurrency)")
        }

        let maxConcurrent = adjustedConcurrency

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
                let filename = filenames[index]

                group.addTask {
                    // Wait for semaphore inside the task
                    await semaphore.wait()

                    // Ensure signal is called when task completes
                    defer {
                        semaphore.signal()
                    }

                    do {
                        let fileURL = outputDirectory.appendingPathComponent(filename)

                        // Add debugging for the problematic email range
                        if index >= 435 && index <= 450 {
                            print("🔍 Processing PDF #\(index + 1): \(email.subject.prefix(50))")
                            print("   Email body length: \(email.body.count) chars")
                        }

                        // Handle extremely large emails that could cause memory issues
                        // Increased to 25MB to effectively remove truncation for most emails
                        let maxPDFContentSize = 25_000_000 // 25MB limit for PDF content
                        var processedEmail = email

                        if email.body.count > maxPDFContentSize {
                            print("⚠️ PDF #\(index + 1) content too large (\(email.body.count) chars), truncating to \(maxPDFContentSize)")

                            // Create truncated email for PDF generation
                            let truncatedBody = String(email.body.prefix(maxPDFContentSize))
                            let truncationNotice = "\n\n" + String(repeating: "=", count: 50) + "\n"
                            let truncationMessage = "[CONTENT TRUNCATED FOR PDF - Original size: \(String(format: "%.1f", Double(email.body.count) / 1_000_000))MB]\n"
                            let finalNotice = "[Truncated \(String(format: "%.1f", Double(email.body.count - maxPDFContentSize) / 1_000_000))MB of content]\n"
                            let endNotice = String(repeating: "=", count: 50)

                            processedEmail = Email(
                                index: email.index,
                                subject: email.subject,
                                from: email.from,
                                to: email.to,
                                cc: email.cc,
                                date: email.date,
                                dateString: email.dateString,
                                body: truncatedBody + truncationNotice + truncationMessage + finalNotice + endNotice,
                                attachments: email.attachments,
                                attachmentData: email.attachmentData,
                                sourceFile: email.sourceFile
                            )
                        }

                        let pdfDocument = PDFDocument()
                        if let page = await createPage(for: processedEmail, pageNumber: 1, totalPages: 1, settings: settings) {
                            pdfDocument.insert(page, at: 0)
                        }

                        guard pdfDocument.write(to: fileURL) else {
                            throw GeneratorError.saveFailed("Could not write to \(fileURL.path)")
                        }

                        // Store result
                        await resultStore.addURL(fileURL)

                        // Update progress
                        await progressTracker.increment()

                        if index >= 435 && index <= 450 {
                            print("✅ Completed PDF #\(index + 1)")
                        }

                        // Yield control every 25 PDFs for better responsiveness with large content
                        if index % 25 == 0 {
                            await Task.yield()
                        }
                    } catch {
                        if index >= 435 && index <= 450 {
                            print("❌ Failed PDF #\(index + 1): \(error)")
                        }
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

        // Handle non-text attachments bundling for separate PDFs mode
        if settings.bundleNonTextAttachments {
            let attachmentsZipURL = outputDirectory.appendingPathComponent("attachments.zip")
            try saveNonTextAttachments(from: emails, to: attachmentsZipURL)
        }

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

        nonisolated func signal() {
            Task {
                await self._signal()
            }
        }

        private func _signal() {
            if !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                waiter.resume()
            } else if count > 0 {
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

            // Calculate the required size for the content
            let boundingSize = CGSize(width: contentRect.width, height: CGFloat.greatestFiniteMagnitude)
            let requiredRect = content.boundingRect(with: boundingSize, options: [.usesLineFragmentOrigin, .usesFontLeading])

            // If content is too long for the page, show truncation warning
            if requiredRect.height > contentRect.height {
                // Draw as much content as fits
                content.draw(in: contentRect)

                // Add truncation warning at bottom
                let warningFont = NSFont.systemFont(ofSize: 8)
                let warningAttributes: [NSAttributedString.Key: Any] = [
                    .font: warningFont,
                    .foregroundColor: NSColor.red,
                    .backgroundColor: NSColor.white
                ]

                let excessHeight = requiredRect.height - contentRect.height
                let warningText = "⚠️ CONTENT TRUNCATED - \(Int(excessHeight)) points of content not shown"
                let warning = NSAttributedString(string: warningText, attributes: warningAttributes)

                let warningRect = CGRect(
                    x: contentRect.minX,
                    y: contentRect.minY + 5, // Small margin from bottom
                    width: contentRect.width,
                    height: 20
                )

                warning.draw(in: warningRect)
            } else {
                // Content fits, draw normally
                content.draw(in: contentRect)
            }
        }
    }

    private static func createPage(for email: Email, pageNumber: Int, totalPages: Int, settings: AppSettings) async -> PDFPage? {
        // Add timeout protection for very large content
        return await withTaskGroup(of: PDFPage?.self) { group in
            group.addTask {
                // Create an NSAttributedString for the content
                let content = createAttributedContent(for: email, pageNumber: pageNumber, totalPages: totalPages, settings: settings)

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
                    autoreleasepool {
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
            }

            // Add timeout task
            group.addTask {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 second timeout
                return nil
            }

            // Return first completed result (either success or timeout)
            for await result in group {
                group.cancelAll()
                return result
            }

            return nil
        }
    }

    nonisolated private static func createAttributedContent(for email: Email, pageNumber: Int, totalPages: Int, settings: AppSettings) -> NSAttributedString {
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

        // Add merged attachments if enabled
        if settings.mergeAttachmentsIntoPDF, let attachments = email.attachmentData {
            let mergeableAttachments = attachments.filter { $0.canMergeIntoPDF }
            if !mergeableAttachments.isEmpty {
                content.append(NSAttributedString(string: "\n" + String(repeating: "─", count: 50) + "\n", attributes: headerAttributes))
                content.append(NSAttributedString(string: "ATTACHMENTS\n\n", attributes: titleAttributes))

                for attachment in mergeableAttachments {
                    content.append(NSAttributedString(string: "\n[\(attachment.filename)]\n", attributes: headerAttributes))

                    if attachment.isImage {
                        // Add image
                        if let image = NSImage(data: attachment.data) {
                            // Resize image to fit in page width
                            let maxWidth: CGFloat = 504 // Page width minus margins
                            let maxHeight: CGFloat = 300 // Reasonable max height
                            let imageSize = image.size
                            var targetSize = imageSize

                            if imageSize.width > maxWidth {
                                let ratio = maxWidth / imageSize.width
                                targetSize = CGSize(width: maxWidth, height: imageSize.height * ratio)
                            }

                            if targetSize.height > maxHeight {
                                let ratio = maxHeight / targetSize.height
                                targetSize = CGSize(width: targetSize.width * ratio, height: maxHeight)
                            }

                            let textAttachment = NSTextAttachment()
                            textAttachment.image = image
                            textAttachment.bounds = CGRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)

                            content.append(NSAttributedString(attachment: textAttachment))
                            content.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
                        }
                    } else if attachment.isText {
                        // Add text content
                        if let text = String(data: attachment.data, encoding: .utf8) {
                            let truncatedText = text.count > 5000 ? String(text.prefix(5000)) + "\n...[truncated]" : text
                            content.append(NSAttributedString(string: truncatedText + "\n\n", attributes: bodyAttributes))
                        }
                    }
                }
            }
        }

        return content
    }

    static func saveNonTextAttachments(from emails: [Email], to outputURL: URL) throws {
        // Collect all non-text attachments
        var attachmentFiles: [URL] = []
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        defer {
            // Clean up temp directory
            try? FileManager.default.removeItem(at: tempDir)
        }

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            for email in emails {
                guard let attachments = email.attachmentData else { continue }

                let nonTextAttachments = attachments.filter { !$0.canMergeIntoPDF }

                for (index, attachment) in nonTextAttachments.enumerated() {
                    // Create unique filename to avoid collisions
                    var filename = attachment.filename
                    let emailPrefix = "email_\(email.index)_"

                    // Check if filename already has the prefix to avoid duplication
                    if !filename.hasPrefix(emailPrefix) {
                        filename = emailPrefix + filename
                    }

                    // If there are multiple attachments with same name in same email
                    if nonTextAttachments.filter({ $0.filename == attachment.filename }).count > 1 {
                        let fileExtension = (filename as NSString).pathExtension
                        let fileNameWithoutExt = (filename as NSString).deletingPathExtension
                        filename = "\(fileNameWithoutExt)_\(index + 1).\(fileExtension)"
                    }

                    let fileURL = tempDir.appendingPathComponent(filename)
                    try attachment.data.write(to: fileURL)
                    attachmentFiles.append(fileURL)
                }
            }

            // Only create ZIP if there are attachments
            if !attachmentFiles.isEmpty {
                try createZIPArchive(pdfURLs: attachmentFiles, outputURL: outputURL)
            }
        } catch {
            throw GeneratorError.saveFailed("Failed to save attachments: \(error.localizedDescription)")
        }
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
