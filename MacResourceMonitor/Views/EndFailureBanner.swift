import AppKit
import SwiftUI

/// Quiet end-failure notice. Not red; the table already uses red only for a hovered end control.
struct EndFailureBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.96))
    }
}

extension View {
    func endFailureBanner(_ message: String?) -> some View {
        overlay(alignment: .bottom) {
            if let message {
                EndFailureBanner(message: message)
            }
        }
    }
}
