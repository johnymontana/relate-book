import SwiftUI

extension TagColor {
    /// The palette swatch. A tag with no (or an unknown) colour shows gray.
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }
}

/// A tag on Book detail: tap opens the tag's books; the context menu removes it.
struct TagChip: View {
    let tag: BookTag
    let onRemove: () -> Void
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        Button {
            openRoute(.tag(name: tag.name))
        } label: {
            HStack(spacing: 5) {
                Circle().fill(tag.color?.color ?? .gray).frame(width: 8, height: 8)
                Text(tag.name).lineLimit(1)
            }
            .font(.footnote)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.fill.tertiary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tag.chip.\(tag.name)")
        .accessibilityLabel("Tag \(tag.name)")
        .contextMenu {
            Button("Remove “\(tag.name)”", systemImage: "tag.slash", role: .destructive) { onRemove() }
        }
    }
}

/// A menu item title with a checkmark when selected.
@ViewBuilder func checkLabel(_ title: String, on: Bool) -> some View {
    if on { Label(title, systemImage: "checkmark") } else { Text(title) }
}
