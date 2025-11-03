//
//  SettingsView.swift
//  Unboxed
//
//  Application settings view
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        GeneralSettingsView(settings: settings)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showWarning = false

    var body: some View {
        Form {
            Section("Conversion Options") {
                Toggle("Generate PDF per Email", isOn: $settings.separatePDFs)
                    .help("Creates individual PDF files for each email and packages them in a ZIP file")

                Toggle("Show Email Preview & Selection", isOn: $settings.showEmailPreview)
                    .help("After parsing, show a preview window to search, filter, and select specific emails before conversion")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Concurrent PDF Generation:")
                            .font(.headline)
                        Spacer()
                        Text("\(settings.maxConcurrentPDFs) at a time")
                            .foregroundColor(.secondary)
                    }

                    Picker("Concurrency", selection: $settings.maxConcurrentPDFs) {
                        Text("Sequential (1)").tag(1)
                        Text("Low (2)").tag(2)
                        Text("Medium (4)").tag(4)
                        Text("High (8)").tag(8)
                        Text("Maximum (16)").tag(16)
                    }
                    .pickerStyle(.segmented)

                    Text("Higher concurrency uses more CPU and memory but is faster. Recommended: Medium (4)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Maximum Email Body Size:")
                            .font(.headline)
                        Spacer()
                        Text("\(settings.maxEmailBodySizeMB) MB")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: Binding(
                        get: { Double(settings.maxEmailBodySizeMB) },
                        set: { settings.maxEmailBodySizeMB = Int($0) }
                    ), in: 1...60, step: 1)

                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("Large sizes may cause slow rendering or crashes")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("Email bodies larger than this size will be truncated in exported PDF.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Small (5 MB)") {
                            settings.maxEmailBodySizeMB = 5
                        }
                        .buttonStyle(.bordered)

                        Button("Medium (15 MB)") {
                            settings.maxEmailBodySizeMB = 15
                        }
                        .buttonStyle(.bordered)

                        Button("Large (30 MB)") {
                            settings.maxEmailBodySizeMB = 30
                        }
                        .buttonStyle(.bordered)

                        Button("Max (60 MB)") {
                            settings.maxEmailBodySizeMB = 60
                            showWarning = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } header: {
                Text("Performance")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("PDF Filename Components")
                        .font(.headline)

                    Text("Customize the order and components of PDF filenames when creating separate PDFs. (A 6 digit number is always first.)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 8) {
                        ForEach(Array(settings.namingComponents.enumerated()), id: \.element.id) { index, component in
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { settings.namingComponents[index].enabled },
                                    set: { settings.namingComponents[index].enabled = $0 }
                                )) {
                                    Text(component.type.rawValue)
                                }

                                Spacer()

                                // Move up button
                                Button(action: {
                                    if index > 0 {
                                        settings.namingComponents.swapAt(index, index - 1)
                                    }
                                }) {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)

                                // Move down button
                                Button(action: {
                                    if index < settings.namingComponents.count - 1 {
                                        settings.namingComponents.swapAt(index, index + 1)
                                    }
                                }) {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == settings.namingComponents.count - 1)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // Preview
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Preview:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(previewFilename())
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(4)
                    }
                }
            } header: {
                Text("PDF Naming (Separate PDFs Only)")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .alert("Warning: High Memory Usage", isPresented: $showWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Setting the maximum body size to 60 MB may cause the application to become slow or crash when processing emails with large attachments or content. Use with caution.")
        }
    }

    private func previewFilename() -> String {
        let sampleEmail = Email(
            index: 1,
            subject: "Sample Subject",
            from: "sender@example.com",
            to: "recipient@example.com",
            cc: nil,
            date: Date(),
            dateString: "2024-01-15 10:30:00",
            body: "",
            attachments: [],
            sourceFile: "sample"
        )

        return settings.buildFilename(for: sampleEmail, index: 1)
    }
}

#Preview {
    SettingsView(settings: AppSettings())
}
