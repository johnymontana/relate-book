import SwiftUI

/// A search result: the shared `BookRow` plus a small "why it matched"
/// line. One combined accessibility element whose label starts with the
/// book title (the UI test matches on that prefix).
struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BookRow(book: result.book)
            HStack(spacing: 4) {
                Image(systemName: result.hit.reason.systemImage)
                Text(result.hit.detailText)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 60)
        }
        .accessibilityElement(children: .combine)
    }
}
