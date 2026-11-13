import SwiftUI

/// The thin banner shown while the indexer embeds books: a determinate
/// bar (no spinner, so XCUITest can reach idle) and "Indexing 412 of
/// 1,811 books…".
struct IndexingBanner: View {
    let progress: IndexingProgress

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: progress.fractionComplete)
                .frame(width: 64)
            Text(progress.bannerText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("index.banner")
    }
}
