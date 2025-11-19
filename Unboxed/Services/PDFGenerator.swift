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
            // Create pages for this email (may be multiple pages for long content)
            let pages = await MainActor.run {
                createPages(for: email, emailNumber: index + 1, totalEmails: emails.count, settings: settings)
            }
            for page in pages {
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

                        // With multi-page support, we no longer need to pre-truncate content
                        // The pagination will handle long emails by creating multiple pages

                        let pdfDocument = PDFDocument()
                        // Create pages for this email (may be multiple pages for long content)
                        let pages = await MainActor.run {
                            createPages(for: email, emailNumber: 1, totalEmails: 1, settings: settings)
                        }
                        for (pageIndex, page) in pages.enumerated() {
                            pdfDocument.insert(page, at: pageIndex)
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

    // Custom view for rendering email content to PDF (single page or portion)
    private class EmailContentView: NSView {
        private let content: NSAttributedString
        private let contentRect: CGRect
        private let characterRange: NSRange
        private let showPageFooter: Bool
        private let pageInfo: String?

        init(frame: NSRect, content: NSAttributedString, contentRect: CGRect, characterRange: NSRange, showPageFooter: Bool = false, pageInfo: String? = nil) {
            self.content = content
            self.contentRect = contentRect
            self.characterRange = characterRange
            self.showPageFooter = showPageFooter
            self.pageInfo = pageInfo
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        // Use flipped coordinate system (origin at top-left)
        override var isFlipped: Bool {
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            // Fill background with white
            NSColor.white.setFill()
            dirtyRect.fill()

            // Use NSLayoutManager for proper text layout and rendering
            let textStorage = NSTextStorage(attributedString: content)
            let layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)
            
            let textContainer = NSTextContainer(size: CGSize(width: contentRect.width, height: CGFloat.greatestFiniteMagnitude))
            textContainer.lineFragmentPadding = 0
            layoutManager.addTextContainer(textContainer)
            
            // Force layout
            layoutManager.glyphRange(for: textContainer)
            
            // Draw only the specified character range
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            let boundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            
            // Calculate offset to position content correctly at the top of the page
            let yOffset = contentRect.minY - boundingRect.minY
            
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: CGPoint(x: contentRect.minX, y: yOffset))
            
            // Draw page footer if requested
            if showPageFooter, let pageInfo = pageInfo {
                let footerFont = NSFont.systemFont(ofSize: 8)
                let footerAttributes: [NSAttributedString.Key: Any] = [
                    .font: footerFont,
                    .foregroundColor: NSColor.gray
                ]
                let footerText = NSAttributedString(string: pageInfo, attributes: footerAttributes)
                let footerRect = CGRect(
                    x: contentRect.minX,
                    y: bounds.height - 35, // Position near bottom
                    width: contentRect.width,
                    height: 15
                )
                footerText.draw(in: footerRect)
            }
        }
    }

    @MainActor
    private static func createPages(for email: Email, emailNumber: Int, totalEmails: Int, settings: AppSettings) -> [PDFPage] {
        // Create attributed content
        let content = createAttributedContent(for: email, pageNumber: emailNumber, totalPages: totalEmails, settings: settings)
        
        // Page dimensions (US Letter)
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // 8.5" x 11" at 72 DPI
        let margin: CGFloat = 54 // 0.75" margins
        let contentRect = CGRect(
            x: margin,
            y: margin,
            width: pageRect.width - (2 * margin),
            height: pageRect.height - (2 * margin)
        )
        
        // Use NSLayoutManager to calculate pagination
        let textStorage = NSTextStorage(attributedString: content)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        
        let textContainer = NSTextContainer(size: CGSize(width: contentRect.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        
        // Force layout to calculate glyph positions
        _ = layoutManager.glyphRange(for: textContainer)
        
        // Calculate character ranges for each page
        var pages: [PDFPage] = []
        var currentCharIndex = 0
        var pageNumber = 1
        
        while currentCharIndex < content.length {
            let isFirstPage = (pageNumber == 1)
            let availableHeight = isFirstPage ? contentRect.height : (contentRect.height - 30) // Reserve space for footer
            
            // Binary search to find the right character range that fits in availableHeight
            var low = currentCharIndex
            var high = content.length
            var bestFit = currentCharIndex
            
            while low < high {
                let mid = (low + high + 1) / 2
                let testRange = NSRange(location: currentCharIndex, length: mid - currentCharIndex)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: testRange, actualCharacterRange: nil)
                let boundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                
                if boundingRect.height <= availableHeight {
                    bestFit = mid
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            
            // If no progress, force at least some characters (prevent infinite loop)
            if bestFit == currentCharIndex {
                bestFit = min(currentCharIndex + 100, content.length)
            }
            
            let pageCharacterRange = NSRange(location: currentCharIndex, length: bestFit - currentCharIndex)
            
            // Calculate total pages for footer
            let remainingChars = content.length - bestFit
            let estimatedRemainingPages = remainingChars > 0 ? Int(ceil(Double(remainingChars) / Double(pageCharacterRange.length))) : 0
            let totalPagesNeeded = pageNumber + estimatedRemainingPages
            
            let pageInfo = isFirstPage ? nil : "Page \(pageNumber) of \(totalPagesNeeded)"
            
            if let page = createSinglePage(
                content: content,
                pageRect: pageRect,
                contentRect: contentRect,
                characterRange: pageCharacterRange,
                pageInfo: pageInfo
            ) {
                pages.append(page)
            }
            
            currentCharIndex = bestFit
            pageNumber += 1
            
            // Safety limit
            if pageNumber > 1000 {
                print("⚠️ Reached page limit for email #\(emailNumber), stopping pagination")
                break
            }
        }
        
        return pages
    }
    
    @MainActor
    private static func createSinglePage(content: NSAttributedString, pageRect: CGRect, contentRect: CGRect, characterRange: NSRange, pageInfo: String?) -> PDFPage? {
        return autoreleasepool {
            let view = EmailContentView(
                frame: pageRect,
                content: content,
                contentRect: contentRect,
                characterRange: characterRange,
                showPageFooter: pageInfo != nil,
                pageInfo: pageInfo
            )
            
            let pdfData = view.dataWithPDF(inside: pageRect)
            
            guard let pdfDoc = PDFDocument(data: pdfData),
                  let pdfPage = pdfDoc.page(at: 0) else {
                return nil
            }
            
            return pdfPage
        }
    }

    @MainActor private static func createAttributedContent(for email: Email, pageNumber: Int, totalPages: Int, settings: AppSettings) -> NSAttributedString {
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
        
        if email.body.isEmpty {
            content.append(NSAttributedString(string: "(No content)\n", attributes: bodyAttributes))
        } else if isHTMLContent(email.body), let htmlAttributedString = createHTMLAttributedString(from: email.body) {
            // Successfully rendered as HTML with formatting preserved
            content.append(htmlAttributedString)
            content.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        } else {
            // Fallback to plain text
            content.append(NSAttributedString(string: email.body + "\n", attributes: bodyAttributes))
        }

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
    
    nonisolated private static func isHTMLContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for common HTML patterns
        let htmlPatterns = [
            "<html", "<body", "<div", "<table", "<tr", "<td", "<th",
            "<p>", "<br>", "<br/>", "<span", "<a ", "<img", "<h1", "<h2", "<h3",
            "<ul", "<ol", "<li", "<strong", "<em", "<b>", "<i>", "<style"
        ]
        
        let lowercased = trimmed.lowercased()
        
        // If it starts with common HTML tags, it's definitely HTML
        if lowercased.hasPrefix("<!doctype html") || lowercased.hasPrefix("<html") {
            return true
        }
        
        // Check if it contains multiple HTML tags (not just one or two)
        let tagCount = htmlPatterns.filter { lowercased.contains($0) }.count
        return tagCount >= 2
    }
    
    nonisolated private static func createHTMLAttributedString(from html: String) -> NSAttributedString? {
        // Clean up the HTML first
        var cleanedHTML = html
        
        // Remove any MIME boundary markers that might have slipped through
        cleanedHTML = cleanedHTML.replacingOccurrences(of: #"--[0-9a-fA-F]{20,}--?"#, with: "", options: .regularExpression)
        
        // Remove broken/incomplete HTML tag fragments at the start
        // Matches things like: tyle="..." or div style="..." without opening <
        if let regex = try? NSRegularExpression(pattern: "^[a-zA-Z]+=\"[^\"]*\">", options: []) {
            cleanedHTML = regex.stringByReplacingMatches(in: cleanedHTML, range: NSRange(cleanedHTML.startIndex..., in: cleanedHTML), withTemplate: "")
        }
        
        // Remove broken tag fragments (incomplete opening/closing tags)
        if let regex = try? NSRegularExpression(pattern: "^[^<]*>", options: []) {
            let trimmed = cleanedHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.hasPrefix("<") {
                cleanedHTML = regex.stringByReplacingMatches(in: cleanedHTML, range: NSRange(cleanedHTML.startIndex..., in: cleanedHTML), withTemplate: "")
            }
        }
        
        cleanedHTML = cleanedHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Prepare HTML with proper charset and basic styling
        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', Helvetica, Arial, sans-serif;
                    font-size: 10pt;
                    line-height: 1.4;
                    color: #000000;
                    margin: 0;
                    padding: 0;
                }
                table {
                    border-collapse: collapse;
                    margin: 10px 0;
                    font-size: 9pt;
                }
                td, th {
                    border: 1px solid #cccccc;
                    padding: 4px 8px;
                    vertical-align: top;
                }
                th {
                    background-color: #f0f0f0;
                    font-weight: bold;
                }
                blockquote {
                    margin: 10px 0;
                    padding-left: 10px;
                    border-left: 2px solid #cccccc;
                    color: #666666;
                }
                pre {
                    background-color: #f5f5f5;
                    padding: 8px;
                    border-radius: 3px;
                    overflow-x: auto;
                    font-size: 9pt;
                }
                code {
                    background-color: #f5f5f5;
                    padding: 2px 4px;
                    border-radius: 3px;
                    font-family: 'Monaco', 'Courier New', monospace;
                    font-size: 9pt;
                }
                a {
                    color: #0066cc;
                    text-decoration: underline;
                }
                img {
                    max-width: 100%;
                    height: auto;
                }
                h1, h2, h3, h4, h5, h6 {
                    margin: 10px 0 5px 0;
                    line-height: 1.2;
                }
                h1 { font-size: 14pt; }
                h2 { font-size: 12pt; }
                h3 { font-size: 11pt; }
                p {
                    margin: 5px 0;
                }
                ul, ol {
                    margin: 5px 0;
                    padding-left: 20px;
                }
                li {
                    margin: 2px 0;
                }
            </style>
        </head>
        <body>
        \(cleanedHTML)
        </body>
        </html>
        """
        
        guard let data = styledHTML.data(using: .utf8) else {
            return nil
        }
        
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        
        // Try to create attributed string from HTML
        if let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributedString
        }
        
        return nil
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
