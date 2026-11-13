import SwiftUI

/// The place sheet: header facts, the books set there (paged, title order)
/// and the authors born there. Its own NavigationStack pushes Book detail
/// and Author pages inside the sheet.
struct PlaceSheet: View {
    let model: PlaceSheetModel
    let session: AppSession
    let onClose: () -> Void
    @State private var path: [Route] = []
    @State private var showAllAuthors = false
    private let authorLimit = 50

    var body: some View {
        NavigationStack(path: $path) {
            List {
                header
                booksSection
                authorsSection
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("place.sheet")
            // Drag up for .large. Programmatic detent selection (to grow the
            // sheet on push) had no effect on the iOS 26.5 simulator, so the
            // sheet keeps the detent the user chose.
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("place.close")
                }
            }
            .navigationDestination(for: Route.self) { route in
                RouteDestination(route: route, session: session)
            }
        }
        .environment(\.openRoute, OpenRouteAction { route in path.append(route) })
        .environment(\.replaceRoute, ReplaceRouteAction { route in path.append(route) })
        .task { await model.load() }
    }

    // MARK: Sections

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("PLACE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.label)
                    .font(.title3.weight(.bold))
                    .accessibilityIdentifier("place.title")
                if let summary = model.summary {
                    Text(summary.bookCount == 0 ? "No books set here" : PlaceText.books(summary.bookCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("place.bookCount")
                    if summary.authorCount > 0 {
                        Text("\(PlaceText.authors(summary.authorCount)) born here")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("place.authorCount")
                    }
                    if !summary.otherNames.isEmpty {
                        Text("Also filed as: " + summary.otherNames.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityIdentifier("place.headings")
                    }
                } else if model.hasLoadedSummary {
                    Text(model.error ?? "This place is not on the map.")
                        .font(.footnote)
                        .foregroundStyle(model.error == nil ? Color.secondary : Color.red)
                } else {
                    ProgressView()
                }
            }
        }
    }

    private var booksSection: some View {
        Section(booksTitle) {
            ForEach(Array(model.books.books.enumerated()), id: \.element.id) { i, book in
                BookLinkRow(book: book)
                    .accessibilityIdentifier("place.book.\(i)")
                    .task { await model.books.loadMoreIfNeeded(current: book) }
            }
            if model.books.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let error = model.books.error {
                Text(error).foregroundStyle(.red).font(.footnote)
            } else if model.books.hasLoaded && model.books.books.isEmpty {
                Text("No books set here.").foregroundStyle(.secondary)
            }
        }
    }

    private var booksTitle: String {
        if let count = model.summary?.bookCount { return "Books set here (\(count))" }
        return "Books set here"
    }

    @ViewBuilder private var authorsSection: some View {
        if !model.authors.isEmpty {
            Section("Authors born here (\(model.authors.count))") {
                let shown = showAllAuthors ? model.authors : Array(model.authors.prefix(authorLimit))
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, author in
                    NavigationLink(value: Route.author(key: author.key)) {
                        LabeledContent(author.name, value: PlaceText.books(author.bookCount))
                    }
                    .accessibilityIdentifier("place.author.\(i)")
                }
                if model.authors.count > authorLimit {
                    Button(showAllAuthors ? "Show fewer" : "Show all \(model.authors.count)") {
                        showAllAuthors.toggle()
                    }
                    .font(.footnote)
                }
            }
        }
    }
}
