//
//  EmailPreviewView.swift
//  Unboxed
//
//  Email preview and selection view
//

import SwiftUI

nonisolated enum EmailSortOrder: String, CaseIterable, Sendable {
    case dateDescending = "Date (Newest First)"
    case dateAscending = "Date (Oldest First)"
    case subject = "Subject"
    case sender = "Sender"

    var systemImage: String {
        switch self {
        case .dateDescending: return "arrow.down"
        case .dateAscending: return "arrow.up"
        case .subject: return "text.alignleft"
        case .sender: return "person"
        }
    }
}

struct EmailPreviewView: View {
    @ObservedObject var model: ConversionViewModel
    let preferHTML: Bool
    let onConfirm: () -> Void

    @State private var sortOrder: EmailSortOrder = .dateDescending
    @State private var activeID: Int?
    /// The filtered, sorted list. Recomputed in the background only when the
    /// search text or sort order changes, never on every redraw.
    @State private var displayed: [EmailSummary] = []
    @State private var hasLoaded = false
    @State private var isSearchingBodies = false

    private struct Query: Hashable {
        var text: String
        var sort: EmailSortOrder
        var count: Int
    }

    private var selectedCount: Int { model.selectedIDs.count }

    private var activeEmail: EmailSummary? {
        guard let activeID else { return nil }
        // ids are 1-based positions in `emails`
        if activeID >= 1, activeID <= model.emails.count, model.emails[activeID - 1].id == activeID {
            return model.emails[activeID - 1]
        }
        return model.emails.first { $0.id == activeID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()

            Divider()

            HSplitView {
                emailListView

                if let email = activeEmail {
                    EmailDetailView(email: email, files: model.mappedFiles, preferHTML: preferHTML)
                        .frame(minWidth: 400)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "envelope.open")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Select an email to preview")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }

            Divider()

            // Bottom bar
            HStack {
                Button("Cancel") {
                    model.showEmailPreview = false
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Convert Selected (\(selectedCount))") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCount == 0)
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 500)
        .task(id: Query(text: model.searchText, sort: sortOrder, count: model.emails.count)) {
            await refresh()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Email Preview & Selection")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button(action: { model.showEmailPreview = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search emails...", text: $model.searchText)
                        .textFieldStyle(.plain)
                    if isSearchingBodies {
                        ProgressView()
                            .controlSize(.small)
                            .help("Searching message bodies…")
                    }
                    if !model.searchText.isEmpty {
                        Button(action: { model.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)

                // Sort picker
                Picker("Sort", selection: $sortOrder) {
                    ForEach(EmailSortOrder.allCases, id: \.self) { order in
                        HStack {
                            Image(systemName: order.systemImage)
                            Text(order.rawValue)
                        }
                        .tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }

            // Selection controls
            HStack {
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(model.searchText.isEmpty ? "Select All" : "Select Shown") {
                    model.selectedIDs.formUnion(displayed.map(\.id))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if !model.searchText.isEmpty {
                    Button("Deselect Shown") {
                        model.selectedIDs.subtract(displayed.map(\.id))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button("Deselect All") {
                    model.selectedIDs.removeAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var selectionSummary: String {
        if model.searchText.isEmpty {
            return "\(selectedCount) of \(model.emails.count) selected"
        }
        return "\(selectedCount) of \(model.emails.count) selected · \(displayed.count) shown"
    }

    // MARK: - List

    private var emailListView: some View {
        Group {
            if !hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayed.isEmpty {
                Text(isSearchingBodies ? "Searching…" : "No matching emails")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(displayed, selection: $activeID) { email in
                    EmailRow(
                        email: email,
                        isSelected: model.selectedIDs.contains(email.id),
                        toggle: { toggle(email.id) }
                    )
                    .tag(email.id)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 300, idealWidth: 380)
    }

    private func toggle(_ id: Int) {
        if model.selectedIDs.contains(id) {
            model.selectedIDs.remove(id)
        } else {
            model.selectedIDs.insert(id)
        }
    }

    // MARK: - Filtering

    private func refresh() async {
        let emails = model.emails
        let files = model.mappedFiles
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        let sort = sortOrder

        if hasLoaded && !query.isEmpty {
            // Debounce typing.
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
        }

        // Headers first: instant.
        let headerMatches = await Task.detached(priority: .userInitiated) {
            EmailPreviewView.filterAndSort(emails, query: query, sort: sort, bodyMatches: [])
        }.value
        if Task.isCancelled { return }
        displayed = headerMatches
        hasLoaded = true
        isSearchingBodies = false

        guard query.count >= 2 else { return }

        // Then message bodies, read on demand from the mapped files.
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Task.isCancelled { return }
        isSearchingBodies = true
        let alreadyMatched = Set(headerMatches.map(\.id))
        let cancel = CancelFlag()
        let bodyMatches = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                MBOXIndexer.searchBodies(query: query, in: emails.filter { !alreadyMatched.contains($0.id) }, files: files, cancel: cancel)
            }.value
        } onCancel: {
            cancel.cancel()
        }
        if Task.isCancelled { return }
        isSearchingBodies = false
        guard !bodyMatches.isEmpty else { return }

        let combined = await Task.detached(priority: .userInitiated) {
            EmailPreviewView.filterAndSort(emails, query: query, sort: sort, bodyMatches: bodyMatches)
        }.value
        if Task.isCancelled { return }
        displayed = combined
    }

    nonisolated static func filterAndSort(_ emails: [EmailSummary], query: String, sort: EmailSortOrder, bodyMatches: Set<Int>) -> [EmailSummary] {
        var result = emails
        if !query.isEmpty {
            result = emails.filter { email in
                bodyMatches.contains(email.id)
                    || email.subject.localizedCaseInsensitiveContains(query)
                    || email.from.localizedCaseInsensitiveContains(query)
                    || email.to.localizedCaseInsensitiveContains(query)
            }
        }

        switch sort {
        case .dateDescending:
            result.sort { ($0.date ?? .distantPast, $1.id) > ($1.date ?? .distantPast, $0.id) }
        case .dateAscending:
            result.sort { ($0.date ?? .distantPast, $0.id) < ($1.date ?? .distantPast, $1.id) }
        case .subject:
            result.sort { $0.subject.localizedCaseInsensitiveCompare($1.subject) == .orderedAscending }
        case .sender:
            result.sort { $0.from.localizedCaseInsensitiveCompare($1.from) == .orderedAscending }
        }
        return result
    }
}

// MARK: - Row

private struct EmailRow: View {
    let email: EmailSummary
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: toggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .blue : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(email.subject)
                    .font(.body)
                    .lineLimit(2)

                Text(email.from)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let date = email.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if !email.attachments.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "paperclip")
                            Text("\(email.attachments.count)")
                        }
                        .font(.caption2)
                        .foregroundColor(.blue)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

private struct EmailDetailView: View {
    let email: EmailSummary
    let files: [MappedFile]
    let preferHTML: Bool

    @State private var bodyText: NSAttributedString?
    @State private var loadedID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(email.subject)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)

                headerLine("From:", email.from)
                headerLine("To:", email.to)
                if let cc = email.cc, !cc.isEmpty {
                    headerLine("CC:", cc)
                }
                if let date = email.date {
                    headerLine("Date:", date.formatted(date: .long, time: .shortened))
                }

                if !email.attachments.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "paperclip")
                            .foregroundColor(.blue)
                        Text(email.attachments.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.blue)
                            .lineLimit(3)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            if let bodyText, loadedID == email.id {
                AttributedTextView(text: bodyText, identity: email.id)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .task(id: email.id) {
            let summary = email
            let files = files
            let preferHTML = preferHTML
            let rendered = await Task.detached(priority: .userInitiated) {
                let options = MBOXIndexer.LoadOptions(preferHTML: preferHTML, loadAttachmentData: false, maxBodyLength: 300_000)
                let parsed = MBOXIndexer.load(summary, files: files, options: options)
                return UncheckedTransfer(value: PDFRenderer.bodyContent(for: parsed, fontSize: 13, maxImageWidth: 520))
            }.value
            if Task.isCancelled { return }
            bodyText = rendered.value
            loadedID = summary.id
        }
    }

    private func headerLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

/// Read-only, scrollable rich text. Shown on a white "page" so the preview
/// matches the PDF output in both light and dark mode.
private struct AttributedTextView: NSViewRepresentable {
    let text: NSAttributedString
    let identity: Int

    final class Coordinator {
        var identity: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white

        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = true
            textView.backgroundColor = .white
            textView.textContainerInset = NSSize(width: 16, height: 16)
            textView.isAutomaticLinkDetectionEnabled = false
            textView.layoutManager?.allowsNonContiguousLayout = true
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Only replace the text when a different email is shown.
        guard context.coordinator.identity != identity,
              let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.identity = identity
        textView.textStorage?.setAttributedString(text)
        textView.scroll(.zero)
    }
}
