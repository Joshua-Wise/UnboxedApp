//
//  ContentView.swift
//  Unboxed
//
//  Main application view
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @StateObject private var historyManager = ConversionHistoryManager()

    var body: some View {
        TabView {
            HomeView(settings: settings, historyManager: historyManager)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            HistoryView(historyManager: historyManager)
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            SettingsView(settings: settings)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .frame(minWidth: 900, minHeight: 700)
    }
}

struct HomeView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var historyManager: ConversionHistoryManager
    @State private var selectedFiles: [URL] = []
    @State private var isProcessing = false
    @State private var progress: Double = 0.0
    @State private var statusMessage = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showSuccess = false
    @State private var successMessage = ""
    @State private var isDragging = false
    @State private var shouldCancelProcessing = false
    @State private var conversionStartTime: Date?
    @State private var outputFolderURL: URL?
    @State private var showEmailPreview = false
    @State private var parsedEmails: [Email] = []
    @State private var selectedEmailIndices: Set<Int> = []
    @State private var emailSearchText = ""
    @State private var totalSkippedCount = 0

    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main content
            if selectedFiles.isEmpty && !isProcessing {
                uploadView
            } else if isProcessing {
                processingView
            } else {
                fileListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(errorMessage)
        }
        .alert("Success", isPresented: $showSuccess) {
            if let outputURL = outputFolderURL {
                Button("Open Folder") {
                    NSWorkspace.shared.selectFile(outputURL.path, inFileViewerRootedAtPath: outputURL.deletingLastPathComponent().path)
                    showSuccess = false
                    reset()
                }
            }
            Button("OK") {
                showSuccess = false
                reset()
            }
        } message: {
            Text(successMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFilesRequested)) { notification in
            if let urls = notification.object as? [URL] {
                // Opening from recent files or dock drop
                for url in urls {
                    if !selectedFiles.contains(url) {
                        selectedFiles.append(url)
                    }
                }
            } else {
                // Opening via menu/keyboard shortcut
                selectFiles()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearSelection)) { _ in
            reset()
        }
        .sheet(isPresented: $showEmailPreview) {
            EmailPreviewView(
                emails: $parsedEmails,
                selectedEmailIndices: $selectedEmailIndices,
                searchText: $emailSearchText,
                isShowing: $showEmailPreview,
                onConfirm: {
                    showEmailPreview = false
                    generatePDFs()
                }
            )
        }
    }

    // MARK: - Upload View
    private var uploadView: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("Drop your MBOX files here")
                .font(.title2)
                .fontWeight(.semibold)

            Text("or click to browse")
                .font(.body)
                .foregroundColor(.secondary)

            Text("Supported formats: .mbox, .mbx")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: selectFiles) {
                Text("Choose Files")
                    .padding(.horizontal, 30)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDragging ? Color.blue : Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [10]))
        )
        .padding(40)
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - File List View
    private var fileListView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Selected Files")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Clear") {
                    reset()
                }
                .buttonStyle(.bordered)
            }
            .padding()

            // File list
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(selectedFiles, id: \.path) { file in
                        fileRow(for: file)
                    }
                }
                .padding()
            }

            Divider()

            // Bottom bar
            HStack {
                Spacer()

                Button("Process Files") {
                    processFiles()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFiles.isEmpty)
            }
            .padding()
        }
    }

    private func fileRow(for file: URL) -> some View {
        HStack {
            Image(systemName: "doc.fill")
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.lastPathComponent)
                    .font(.body)
                if let fileSize = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 {
                    Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: {
                selectedFiles.removeAll { $0 == file }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Processing View
    private var processingView: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .frame(width: 300)

            Text(statusMessage)
                .font(.headline)

            Text(String(format: "%.0f%% complete", progress * 100))
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Cancel") {
                shouldCancelProcessing = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "mbox")!, UTType(filenameExtension: "mbx")!]

        if panel.runModal() == .OK {
            selectedFiles = panel.urls
            // Add to recent files
            for url in panel.urls {
                appDelegate?.addToRecentFiles(url)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        var newFiles: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url = url, url.pathExtension.lowercased() == "mbox" || url.pathExtension.lowercased() == "mbx" {
                    DispatchQueue.main.async {
                        if !self.selectedFiles.contains(url) {
                            self.selectedFiles.append(url)
                            newFiles.append(url)
                        }
                        group.leave()
                    }
                } else {
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            // Files added
        }
    }

    private func processFiles() {
        isProcessing = true
        shouldCancelProcessing = false
        statusMessage = "Processing MBOX files..."
        progress = 0.0
        conversionStartTime = Date()

        Task {
            do {
                // Parse all MBOX files
                var allEmails: [Email] = []
                var totalSkipped = 0

                for (index, fileURL) in selectedFiles.enumerated() {
                    // Calculate progress range for this file
                    let fileStartProgress = Double(index) / Double(selectedFiles.count)
                    let fileProgressRange = 1.0 / Double(selectedFiles.count)

                    let parseResult = try await MBOXParserStreaming.parse(
                        fileURL: fileURL,
                        progressCallback: { fileProgress, message in
                            await MainActor.run {
                                self.progress = fileStartProgress + (fileProgress * fileProgressRange)
                                self.statusMessage = "\(fileURL.lastPathComponent): \(message)"
                            }
                        },
                        shouldCancel: { self.shouldCancelProcessing },
                        maxBodySizeBytes: settings.maxEmailBodySizeBytes
                    )

                    allEmails.append(contentsOf: parseResult.emails)
                    totalSkipped += parseResult.skipped.count
                }

                // Store parsed emails
                self.parsedEmails = allEmails
                self.totalSkippedCount = totalSkipped
                self.selectedEmailIndices = Set(allEmails.map { $0.index })

                await MainActor.run {
                    self.isProcessing = false

                    // Show preview if enabled, otherwise go straight to PDF generation
                    if self.settings.showEmailPreview {
                        self.showEmailPreview = true
                    } else {
                        // Generate PDFs immediately without preview
                        self.generatePDFs()
                    }
                }
            } catch {
                await MainActor.run {
                    // Check if it was a user cancellation
                    if let parserError = error as? MBOXParserStreaming.ParserError,
                       case .cancelled = parserError {
                        // User cancelled - log to history
                        isProcessing = false
                        let duration = Date().timeIntervalSince(conversionStartTime ?? Date())
                        let historyItem = ConversionHistoryItem(
                            date: Date(),
                            mboxFiles: selectedFiles.map { $0.lastPathComponent },
                            status: .cancelled,
                            totalEmails: 0,
                            skippedEmails: 0,
                            outputPath: "N/A",
                            outputType: settings.separatePDFs ? .separatePDFs : .singlePDF,
                            duration: duration
                        )
                        historyManager.addItem(historyItem)
                    } else {
                        errorMessage = error.localizedDescription
                        showError = true
                        isProcessing = false

                        // Log to history
                        let duration = Date().timeIntervalSince(conversionStartTime ?? Date())
                        let historyItem = ConversionHistoryItem(
                            date: Date(),
                            mboxFiles: selectedFiles.map { $0.lastPathComponent },
                            status: .failed,
                            totalEmails: 0,
                            skippedEmails: 0,
                            outputPath: error.localizedDescription,
                            outputType: settings.separatePDFs ? .separatePDFs : .singlePDF,
                            duration: duration
                        )
                        historyManager.addItem(historyItem)
                    }
                }
            }
        }
    }

    private func generatePDFs() {
        // Filter emails based on selection
        let selectedEmails = parsedEmails.filter { selectedEmailIndices.contains($0.index) }

        guard !selectedEmails.isEmpty else { return }

        isProcessing = true
        statusMessage = "Generating PDFs..."
        progress = 0.0

        Task {
            do {
                // Generate PDFs - must create panel on main thread
                let (response, outputURL) = await MainActor.run {
                    let savePanel = NSSavePanel()
                    savePanel.canCreateDirectories = true

                    if settings.separatePDFs {
                        savePanel.message = "Choose location for ZIP file"
                        savePanel.allowedContentTypes = [.zip]
                        savePanel.nameFieldStringValue = "emails.zip"
                    } else {
                        savePanel.message = "Choose location for PDF"
                        savePanel.allowedContentTypes = [.pdf]
                        savePanel.nameFieldStringValue = "emails.pdf"
                    }

                    let response = savePanel.runModal()
                    return (response, savePanel.url)
                }

                if response == .OK, let outputURL = outputURL {
                    if settings.separatePDFs {
                        // Generate separate PDFs in temp directory
                        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                        let pdfURLs = try await PDFGenerator.generateSeparatePDFs(
                            emails: selectedEmails,
                            outputDirectory: tempDir,
                            settings: settings,
                            progressCallback: { pdfProgress, message in
                                await MainActor.run {
                                    self.progress = pdfProgress
                                    self.statusMessage = message
                                }
                            }
                        )

                        await MainActor.run {
                            statusMessage = "Creating ZIP archive..."
                            progress = 0.95
                        }

                        try PDFGenerator.createZIPArchive(pdfURLs: pdfURLs, outputURL: outputURL)

                        // Cleanup temp directory
                        try? FileManager.default.removeItem(at: tempDir)

                        await MainActor.run {
                            var message = "Successfully converted \(selectedEmails.count) email(s) to \(pdfURLs.count) PDF file(s)"
                            if totalSkippedCount > 0 {
                                message += "\n\n⚠️ Skipped \(totalSkippedCount) malformed email(s) during parsing\n(Check Xcode console for details)"
                            }
                            successMessage = message
                            outputFolderURL = outputURL
                            showSuccess = true
                            isProcessing = false
                            progress = 1.0

                            // Log to history
                            let duration = Date().timeIntervalSince(conversionStartTime ?? Date())
                            let historyItem = ConversionHistoryItem(
                                date: Date(),
                                mboxFiles: selectedFiles.map { $0.lastPathComponent },
                                status: .success,
                                totalEmails: selectedEmails.count,
                                skippedEmails: totalSkippedCount,
                                outputPath: outputURL.path,
                                outputType: .separatePDFs,
                                duration: duration
                            )
                            historyManager.addItem(historyItem)
                        }
                    } else {
                        try PDFGenerator.generateSinglePDF(emails: selectedEmails, outputURL: outputURL)

                        await MainActor.run {
                            var message = "Successfully converted \(selectedEmails.count) email(s) to PDF"
                            if totalSkippedCount > 0 {
                                message += "\n\n⚠️ Skipped \(totalSkippedCount) malformed email(s) during parsing\n(Check Xcode console for details)"
                            }
                            successMessage = message
                            outputFolderURL = outputURL
                            showSuccess = true
                            isProcessing = false
                            progress = 1.0

                            // Log to history
                            let duration = Date().timeIntervalSince(conversionStartTime ?? Date())
                            let historyItem = ConversionHistoryItem(
                                date: Date(),
                                mboxFiles: selectedFiles.map { $0.lastPathComponent },
                                status: .success,
                                totalEmails: selectedEmails.count,
                                skippedEmails: totalSkippedCount,
                                outputPath: outputURL.path,
                                outputType: .singlePDF,
                                duration: duration
                            )
                            historyManager.addItem(historyItem)
                        }
                    }
                } else {
                    // User cancelled the save dialog
                    await MainActor.run {
                        isProcessing = false
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isProcessing = false

                    // Log to history
                    let duration = Date().timeIntervalSince(conversionStartTime ?? Date())
                    let historyItem = ConversionHistoryItem(
                        date: Date(),
                        mboxFiles: selectedFiles.map { $0.lastPathComponent },
                        status: .failed,
                        totalEmails: 0,
                        skippedEmails: totalSkippedCount,
                        outputPath: error.localizedDescription,
                        outputType: settings.separatePDFs ? .separatePDFs : .singlePDF,
                        duration: duration
                    )
                    historyManager.addItem(historyItem)
                }
            }
        }
    }

    private func reset() {
        selectedFiles.removeAll()
        isProcessing = false
        progress = 0.0
        statusMessage = ""
        shouldCancelProcessing = false
        outputFolderURL = nil
        parsedEmails.removeAll()
        selectedEmailIndices.removeAll()
        emailSearchText = ""
        totalSkippedCount = 0
    }
}

#Preview {
    ContentView()
        .frame(width: 800, height: 600)
}
