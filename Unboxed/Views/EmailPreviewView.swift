//
//  EmailPreviewView.swift
//  Unboxed
//
//  Email preview and selection view
//

import SwiftUI

struct EmailPreviewView: View {
    @Binding var emails: [Email]
    @Binding var selectedEmailIndices: Set<Int>
    @Binding var searchText: String
    @Binding var isShowing: Bool
    let onConfirm: () -> Void

    @State private var sortOrder: SortOrder = .dateDescending
    @State private var selectedEmail: Email?

    enum SortOrder: String, CaseIterable {
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

    var filteredAndSortedEmails: [Email] {
        var result = emails

        // Filter by search text
        if !searchText.isEmpty {
            result = result.filter { email in
                email.subject.localizedCaseInsensitiveContains(searchText) ||
                email.from.localizedCaseInsensitiveContains(searchText) ||
                email.to.localizedCaseInsensitiveContains(searchText) ||
                email.body.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Sort
        switch sortOrder {
        case .dateDescending:
            result.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .dateAscending:
            result.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        case .subject:
            result.sort { $0.subject.localizedCaseInsensitiveCompare($1.subject) == .orderedAscending }
        case .sender:
            result.sort { $0.from.localizedCaseInsensitiveCompare($1.from) == .orderedAscending }
        }

        return result
    }

    var selectedCount: Int {
        selectedEmailIndices.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                HStack {
                    Text("Email Preview & Selection")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Button(action: { isShowing = false }) {
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
                        TextField("Search emails...", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
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
                        ForEach(SortOrder.allCases, id: \.self) { order in
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
                    Text("\(selectedCount) of \(filteredAndSortedEmails.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Select All") {
                        selectedEmailIndices = Set(filteredAndSortedEmails.map { $0.index })
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Deselect All") {
                        selectedEmailIndices.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding()

            Divider()

            // Email list and preview
            HSplitView {
                // Email list
                emailListView

                // Email preview
                if let email = selectedEmail {
                    emailDetailView(email: email)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "envelope.open")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Select an email to preview")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }

            Divider()

            // Bottom bar
            HStack {
                Button("Cancel") {
                    isShowing = false
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Convert Selected (\(selectedCount))") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0)
            }
            .padding()
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var emailListView: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(filteredAndSortedEmails, id: \.index) { email in
                    emailRow(email: email)
                }
            }
            .padding(8)
        }
        .frame(minWidth: 300)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func emailRow(email: Email) -> some View {
        let isSelected = selectedEmailIndices.contains(email.index)
        let isActiveSelection = selectedEmail?.index == email.index

        return HStack(alignment: .top, spacing: 12) {
            // Checkbox
            Button(action: {
                if isSelected {
                    selectedEmailIndices.remove(email.index)
                } else {
                    selectedEmailIndices.insert(email.index)
                }
            }) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .blue : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            // Email info
            VStack(alignment: .leading, spacing: 4) {
                Text(email.subject)
                    .font(.body)
                    .fontWeight(isActiveSelection ? .semibold : .regular)
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

            Spacer()
        }
        .padding(10)
        .background(isActiveSelection ? Color.blue.opacity(0.1) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActiveSelection ? Color.blue : Color.clear, lineWidth: 2)
        )
        .onTapGesture {
            selectedEmail = email
        }
    }

    private func emailDetailView(email: Email) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(email.subject)
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 4) {
                        Text("From:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(email.from)
                            .font(.caption)
                    }

                    HStack(spacing: 4) {
                        Text("To:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(email.to)
                            .font(.caption)
                    }

                    if let cc = email.cc {
                        HStack(spacing: 4) {
                            Text("CC:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(cc)
                                .font(.caption)
                        }
                    }

                    if let date = email.date {
                        HStack(spacing: 4) {
                            Text("Date:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(date.formatted(date: .long, time: .shortened))
                                .font(.caption)
                        }
                    }

                    if !email.attachments.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "paperclip")
                                .foregroundColor(.blue)
                            Text("\(email.attachments.count) attachment\(email.attachments.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                }

                Divider()

                // Body
                EmailBodyView(body: email.body)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .frame(minWidth: 400)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// Helper view to render email body (HTML or plain text)
struct EmailBodyView: NSViewRepresentable {
    let body: String
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        // Try to render as HTML first
        if isHTMLContent(body), let attributedString = createHTMLAttributedString(from: body) {
            textView.textStorage?.setAttributedString(attributedString)
        } else {
            // Fallback to plain text
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.textColor
            ]
            let plainText = NSAttributedString(string: body, attributes: attributes)
            textView.textStorage?.setAttributedString(plainText)
        }
    }
    
    private func isHTMLContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let htmlPatterns = [
            "<html", "<body", "<div", "<table", "<tr", "<td",
            "<p>", "<br>", "<span", "<h1", "<h2", "<h3"
        ]
        
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("<!doctype html") || lowercased.hasPrefix("<html") {
            return true
        }
        
        let tagCount = htmlPatterns.filter { lowercased.contains($0) }.count
        return tagCount >= 2
    }
    
    private func createHTMLAttributedString(from html: String) -> NSAttributedString? {
        // Clean up the HTML first
        var cleanedHTML = html
        
        // Remove any MIME boundary markers
        cleanedHTML = cleanedHTML.replacingOccurrences(of: #"--[0-9a-fA-F]{20,}--?"#, with: "", options: .regularExpression)
        
        // Remove broken/incomplete HTML tag fragments at the start
        if let regex = try? NSRegularExpression(pattern: "^[a-zA-Z]+=\"[^\"]*\">", options: []) {
            cleanedHTML = regex.stringByReplacingMatches(in: cleanedHTML, range: NSRange(cleanedHTML.startIndex..., in: cleanedHTML), withTemplate: "")
        }
        
        // Remove broken tag fragments
        if let regex = try? NSRegularExpression(pattern: "^[^<]*>", options: []) {
            let trimmed = cleanedHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.hasPrefix("<") {
                cleanedHTML = regex.stringByReplacingMatches(in: cleanedHTML, range: NSRange(cleanedHTML.startIndex..., in: cleanedHTML), withTemplate: "")
            }
        }
        
        cleanedHTML = cleanedHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', Helvetica, Arial, sans-serif;
                    font-size: 13pt;
                    line-height: 1.4;
                    color: #000000;
                }
                table {
                    border-collapse: collapse;
                    margin: 10px 0;
                }
                td, th {
                    border: 1px solid #cccccc;
                    padding: 6px 10px;
                }
                th {
                    background-color: #f0f0f0;
                    font-weight: bold;
                }
                a {
                    color: #0066cc;
                    text-decoration: underline;
                }
            </style>
        </head>
        <body>
        \(cleanedHTML)
        </body>
        </html>
        """
        
        guard let data = styledHTML.data(using: .utf8) else { return nil }
        
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        
        return try? NSAttributedString(data: data, options: options, documentAttributes: nil)
    }
}
