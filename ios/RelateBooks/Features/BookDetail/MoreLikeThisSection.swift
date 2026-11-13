import SwiftUI

/// "More like this" on Book detail: the nearest books by stored embedding
/// (`BookDetailModel.loadSimilar`), as a horizontal strip of covers.
struct MoreLikeThisSection: View {
    let similar: LoadState<[BookSummary]>
    /// nil when there is no indexer (keyword-only builds and previews).
    let indexingComplete: Bool?

    var body: some View {
        switch similar {
        case .loaded(let books) where !books.isEmpty:
            Section("More like this") {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(books.enumerated()), id: \.element.key) { i, book in
                            SimilarBookCard(book: book)
                                .accessibilityIdentifier("moreLikeThis.item.\(i)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("moreLikeThis.section")
            }
        case .loaded:
            if indexingComplete == false {
                Section("More like this") {
                    Text("Similar books appear once indexing finishes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        case .loading:
            Section("More like this") {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        case .idle, .failed:
            EmptyView()
        }
    }
}

/// One cover card; taps push the book on the current stack.
private struct SimilarBookCard: View {
    let book: BookSummary
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        Button {
            openRoute(.book(key: book.key))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                CoverImage(urls: book.imageURLs, cornerRadius: 4)
                    .frame(width: 72, height: 108)
                Text(book.title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 84, alignment: .leading)
                Text(book.authorLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 84, alignment: .leading)
            }
            .frame(width: 84, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
