//
//  AboutWindow.swift
//  Unboxed
//
//  About window for app menu
//

import SwiftUI

struct AboutWindow: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 64))
                .foregroundColor(.blue)

            Text("Unboxed")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Version 1.1.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 250)

            VStack(spacing: 8) {
                Text("MBOX to PDF Conversion Utility")
                    .font(.body)
                    .multilineTextAlignment(.center)

                Text("Quickly convert MBOX files to PDF")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 320)
            }

            Spacer()

            Text("© 2025 Unboxed")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(30)
        .frame(width: 400, height: 350)
    }
}

#Preview {
    AboutWindow()
}
