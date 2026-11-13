import SwiftUI

/// Read-only reading-status pill (phase 2 makes it editable).
struct StatusBadge: View {
    let status: ReadingStatus

    var body: some View {
        Text(status.shortLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
            .accessibilityLabel("Status: \(status.label)")
    }

    private var tint: Color {
        switch status {
        case .want: .blue
        case .reading: .orange
        case .read: .green
        }
    }
}
