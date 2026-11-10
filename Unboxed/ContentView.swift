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
        .frame(minWidth: 720, minHeight: 520)
    }
}

struct HomeView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var historyManager: ConversionHistoryManager
    @StateObject private var model = ConversionViewModel()
    @State private var isDragging = false

    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main content
            if model.isProcessing {
                processingView
            } else if model.selectedFiles.isEmpty {
                uploadView
            } else {
                fileListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("Error", isPresented: $model.showError) {
            Button("OK") { model.showError = false }
        } message: {
            Text(model.errorMessage)
        }
        .alert("Success", isPresented: $model.showSuccess) {
            if let outputURL = model.outputURL {
                Button("Open Folder") {
                    NSWorkspace.shared.selectFile(outputURL.path, inFileViewerRootedAtPath: outputURL.deletingLastPathComponent().path)
                    model.showSuccess = false
                    model.reset()
                }
            }
            Button("OK") {
                model.showSuccess = false
                model.reset()
            }
        } message: {
            Text(model.successMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFilesRequested)) { notification in
            if let urls = notification.object as? [URL] {
                // Opening from recent files or dock drop
                model.addFiles(urls)
            } else {
                // Opening via menu/keyboard shortcut
                selectFiles()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearSelection)) { _ in
            model.reset()
        }
        .sheet(isPresented: $model.showEmailPreview) {
            EmailPreviewView(
                model: model,
                preferHTML: settings.preferHTML,
                onConfirm: {
                    model.showEmailPreview = false
                    model.convertSelected(settings: settings, history: historyManager)
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
    private var totalSizeText: String {
        let total = model.selectedFiles.reduce(Int64(0)) { $0 + Self.fileSize($1) }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private var fileListView: some View {
        // The list takes whatever height is left over; the header and the
        // action bar are pinned and always visible.
        List {
            ForEach(model.selectedFiles, id: \.path) { file in
                fileRow(for: file)
            }
        }
        .listStyle(.inset)
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
            return true
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Selected Files")
                        .font(.headline)
                    Text("\(model.selectedFiles.count) file\(model.selectedFiles.count == 1 ? "" : "s") · \(totalSizeText)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button("Add Files…", action: selectFiles)
                    Button("Clear") {
                        model.reset()
                    }
                    Spacer()
                    Button("Process Files") {
                        model.processFiles(settings: settings, history: historyManager)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedFiles.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    private func fileRow(for file: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .foregroundColor(.blue)

            Text(file.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.path)

            Spacer(minLength: 12)

            Text(ByteCountFormatter.string(fromByteCount: Self.fileSize(file), countStyle: .file))
                .font(.callout)
                .foregroundColor(.secondary)
                .monospacedDigit()

            Button(action: {
                model.removeFile(file)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from list")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Processing View
    private var processingView: some View {
        VStack(spacing: 20) {
            ProgressView(value: model.progress, total: 1.0)
                .progressViewStyle(.linear)
                .frame(width: 300)

            Text(model.statusMessage)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)

            Text(String(format: "%.0f%% complete", model.progress * 100))
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()

            Button("Cancel") {
                model.cancel()
            }
            .buttonStyle(.bordered)
            .disabled(model.isCancelling)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions
    private func selectFiles() {
        guard !model.isProcessing else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ["mbox", "mbx"].compactMap { UTType(filenameExtension: $0) }

        if panel.runModal() == .OK {
            model.addFiles(panel.urls)
            // Add to recent files
            for url in panel.urls {
                appDelegate?.addToRecentFiles(url)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, ConversionViewModel.isMBOX(url) else { return }
                Task { @MainActor in
                    model.addFiles([url])
                    appDelegate?.addToRecentFiles(url)
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 800, height: 600)
}
