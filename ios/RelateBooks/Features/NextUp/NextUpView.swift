import SwiftUI

/// "Next up": what the graph around the user's reading suggests. All logic
/// is in `NextUpModel` and `GraphStore.nextUp` (core).
struct NextUpView: View {
    let model: NextUpModel

    var body: some View {
        content
            .navigationTitle("Next Up")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.load() }
            // Coming back from a book whose status or rating changed.
            .onAppear { Task { await model.reloadIfNeeded() } }
            .refreshable { await model.reload() }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Couldn't load suggestions", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .loaded(let next) where next.isEmpty:
            ContentUnavailableView {
                Label("Nothing to suggest yet", systemImage: "sparkles")
            } description: {
                Text("Mark books as read and rate them. Series you started, authors you rated 4 or 5 and award winners you haven't read show up here.")
            }
            .accessibilityIdentifier("nextUp.empty")
        case .loaded(let next):
            list(next)
        }
    }

    private func list(_ next: NextUp) -> some View {
        List {
            if !next.series.isEmpty {
                Section("Continue a series") {
                    ForEach(Array(next.series.enumerated()), id: \.element.id) { i, item in
                        SuggestedBookRow(book: item.book, title: item.name, caption: item.caption, systemImage: "square.stack.3d.up")
                            .accessibilityIdentifier("nextUp.series.\(i)")
                    }
                }
            }
            ForEach(Array(next.authors.enumerated()), id: \.element.id) { i, author in
                Section {
                    ForEach(author.books) { book in
                        BookLinkRow(book: book)
                    }
                    if author.unreadCount > author.books.count, let key = author.authorKey {
                        NavigationLink(value: Route.author(key: key)) {
                            Text("All \(author.unreadCount) unread by \(author.authorName)")
                                .font(.footnote)
                        }
                    }
                } header: {
                    Text("More by \(author.authorName)")
                        .accessibilityIdentifier("nextUp.author.\(i)")
                } footer: {
                    Text(author.caption)
                }
            }
            if !next.awards.isEmpty {
                Section {
                    ForEach(Array(next.awards.enumerated()), id: \.element.id) { i, item in
                        SuggestedBookRow(book: item.book, title: nil, caption: item.caption, systemImage: "rosette")
                            .accessibilityIdentifier("nextUp.award.\(i)")
                    }
                } header: {
                    Text("Award winners you haven't read")
                } footer: {
                    if next.awards.contains(where: { $0.sharedCount > 0 }) {
                        Text("Books that won an award one of your 4- or 5-star books also won come first.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("nextUp.list")
    }
}

/// A book row with the reason it is suggested underneath.
private struct SuggestedBookRow: View {
    let book: BookSummary
    let title: String?
    let caption: String
    let systemImage: String

    var body: some View {
        NavigationLink(value: Route.book(key: book.key)) {
            VStack(alignment: .leading, spacing: 4) {
                BookRow(book: book)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: systemImage)
                    Text(title.map { "\($0) · \(caption)" } ?? caption)
                        .lineLimit(2)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 60)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
