//
//  UnboxedApp.swift
//  Unboxed
//
//  Native macOS MBOX to PDF Converter
//

import SwiftUI
import Combine

@main
struct UnboxedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Unboxed") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            NSApplication.AboutPanelOptionKey.applicationName: "Unboxed",
                            NSApplication.AboutPanelOptionKey.applicationVersion: "1.1.0",
                            NSApplication.AboutPanelOptionKey.version: "",
                            NSApplication.AboutPanelOptionKey.credits: NSAttributedString(
                                string: "MBOX to PDF Conversion Utility",
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 11),
                                    .foregroundColor: NSColor.secondaryLabelColor
                                ]
                            ),
                            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "2025 Unboxed | https://jwise.dev"
                        ]
                    )
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("Open MBOX Files...") {
                    NSApplication.shared.sendAction(#selector(AppDelegate.openFiles), to: nil, from: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Menu("Open Recent") {
                    ForEach(appDelegate.recentFiles, id: \.self) { fileURL in
                        Button(fileURL.lastPathComponent) {
                            appDelegate.openRecentFile(fileURL)
                        }
                    }
                    if !appDelegate.recentFiles.isEmpty {
                        Divider()
                        Button("Clear Recent Files") {
                            appDelegate.clearRecentFiles()
                        }
                    }
                }
            }

            CommandGroup(after: .sidebar) {
                Button("Clear Selection") {
                    NotificationCenter.default.post(name: .clearSelection, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var recentFiles: [URL] = []
    private let maxRecentFiles = 10
    private let recentFilesKey = "RecentMBOXFiles"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register file type associations
        NSApp.servicesProvider = self

        // Load recent files
        loadRecentFiles()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // Handle files opened via drag & drop on dock icon
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.compactMap { URL(fileURLWithPath: $0) }
            .filter { $0.pathExtension.lowercased() == "mbox" || $0.pathExtension.lowercased() == "mbx" }

        if !urls.isEmpty {
            for url in urls {
                addToRecentFiles(url)
            }
            NotificationCenter.default.post(name: .openFilesRequested, object: urls)
        }
    }

    @objc func openFiles() {
        NotificationCenter.default.post(name: .openFilesRequested, object: nil)
    }

    func openRecentFile(_ url: URL) {
        // Check if file still exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            removeFromRecentFiles(url)
            return
        }

        addToRecentFiles(url)
        NotificationCenter.default.post(name: .openFilesRequested, object: [url])
    }

    func addToRecentFiles(_ url: URL) {
        // Remove if already exists
        recentFiles.removeAll { $0 == url }

        // Add to front
        recentFiles.insert(url, at: 0)

        // Keep only max recent files
        if recentFiles.count > maxRecentFiles {
            recentFiles = Array(recentFiles.prefix(maxRecentFiles))
        }

        saveRecentFiles()
    }

    func removeFromRecentFiles(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        saveRecentFiles()
    }

    func clearRecentFiles() {
        recentFiles.removeAll()
        saveRecentFiles()
    }

    private func loadRecentFiles() {
        if let data = UserDefaults.standard.data(forKey: recentFilesKey),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            recentFiles = paths.compactMap { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private func saveRecentFiles() {
        let paths = recentFiles.map { $0.path }
        if let data = try? JSONEncoder().encode(paths) {
            UserDefaults.standard.set(data, forKey: recentFilesKey)
        }
    }
}

extension Notification.Name {
    static let openFilesRequested = Notification.Name("openFilesRequested")
    static let clearSelection = Notification.Name("clearSelection")
}
