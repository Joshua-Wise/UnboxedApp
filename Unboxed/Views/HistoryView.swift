//
//  HistoryView.swift
//  Unboxed
//
//  Conversion history display
//

import SwiftUI
import Combine

struct HistoryView: View {
    @ObservedObject var historyManager: ConversionHistoryManager
    @State private var showingClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // History list
            if historyManager.items.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(historyManager.items) { item in
                            HistoryItemRow(item: item, onDelete: {
                                historyManager.removeItem(item)
                            })
                        }
                    }
                    .padding()
                }

                Divider()

                // Bottom button
                HStack {
                    Spacer()
                    Button("Clear History") {
                        showingClearConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Clear History", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                historyManager.clearHistory()
            }
        } message: {
            Text("Are you sure you want to clear all conversion history? This cannot be undone.")
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Conversion History")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Your conversion history will appear here")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HistoryItemRow: View {
    let item: ConversionHistoryItem
    let onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack {
                // Status icon
                Image(systemName: item.status.icon)
                    .foregroundColor(statusColor)
                    .font(.system(size: 20))

                VStack(alignment: .leading, spacing: 4) {
                    // MBOX files
                    Text(item.mboxFiles.joined(separator: ", "))
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    // Date and stats
                    HStack(spacing: 12) {
                        Label(item.formattedDate, systemImage: "calendar")
                        Label("\(item.totalEmails) emails", systemImage: "envelope")
                        if item.skippedEmails > 0 {
                            Label("\(item.skippedEmails) skipped", systemImage: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                        }
                        Label(item.formattedDuration, systemImage: "clock")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                // Expand/collapse button
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                // Delete button
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            .padding()

            // Expanded details
            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    DetailRow(label: "Status", value: item.status.rawValue)
                    DetailRow(label: "Output Type", value: item.outputType.rawValue)
                    DetailRow(label: "Total Emails", value: "\(item.totalEmails)")
                    if item.skippedEmails > 0 {
                        DetailRow(label: "Skipped Emails", value: "\(item.skippedEmails)")
                    }
                    DetailRow(label: "Duration", value: item.formattedDuration)
                    DetailRow(label: "Output", value: item.outputPath)

                    if item.mboxFiles.count > 1 {
                        Text("Source Files:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(item.mboxFiles, id: \.self) { file in
                            Text("  • \(file)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var statusColor: Color {
        switch item.status {
        case .success:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    HistoryView(historyManager: ConversionHistoryManager())
        .frame(width: 800, height: 600)
}
