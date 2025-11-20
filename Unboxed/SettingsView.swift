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

    var body: some View {
        Form {
            Section("Conversion Options") {
                Toggle("Generate PDF per Email", isOn: $settings.separatePDFs)
                    .help("Creates individual PDF files for each email and packages them in a ZIP file")

                Toggle("Show Email Preview & Selection", isOn: $settings.showEmailPreview)
                    .help("After parsing, show a preview window to search, filter, and select specific emails before conversion")
            }

            Section("Attachment Handling") {
                Toggle("Merge Text/Image Attachments into PDF", isOn: $settings.mergeAttachmentsIntoPDF)
                    .help("When enabled, text and image attachments will be embedded directly into the PDF document")

                Toggle("Bundle Non-Text Attachments", isOn: $settings.bundleNonTextAttachments)
                    .help("When enabled, creates an attachments.zip file containing all non-text/image attachments (e.g., documents, archives, executables)")

                VStack(alignment: .leading, spacing: 4) {
                    Text("Note: Attachments are extracted from MIME multipart email messages.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            attachmentData: nil,
            sourceFile: "sample"
        )

        return settings.buildFilename(for: sampleEmail, index: 1)
    }
}

#Preview {
    SettingsView(settings: AppSettings())
}
