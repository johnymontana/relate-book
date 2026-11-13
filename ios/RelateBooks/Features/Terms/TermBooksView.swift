import SwiftUI

/// The books (and, for places, countries and awards, the authors) linked to
/// one subject, genre, series, place, person, era, publisher, award or country.
/// A place shows "Show on map" when its heading is geocoded, else why not.
struct TermBooksView: View {
    @State var model: TermModel
    @State private var showAllAuthors = false
    @Environment(\.showOnMap) private var showOnMap
    private let authorLimit = 50

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.kind.label.uppercased())
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(model.name).font(.title3.weight(.bold))
                    if let summary = model.summary {
                        Text(summary.bookCount == 1 ? "1 book on the list" : "\(summary.bookCount) books on the list")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.kind == .place, let location = model.placeLocation {
                        if location.isOnMap {
                            Button {
                                showOnMap(model.name)
                            } label: {
                                Label("Show on map", systemImage: "map")
                                    .font(.callout)
                            }
                            .buttonStyle(.borderless)
                            .padding(.top, 2)
                            .accessibilityIdentifier("term.showOnMap")
                        } else {
                            Text(location.notOnMapReason)
                                .font(.caption).foregroundStyle(.tertiary)
                                .accessibilityIdentifier("term.notOnMap")
                        }
                    }
                }
            }
            if !model.authors.isEmpty {
                Section(model.kind.authorSectionTitle + " (\(model.authors.count))") {
                    ForEach(showAllAuthors ? model.authors : Array(model.authors.prefix(authorLimit))) { author in
                        NavigationLink(value: Route.author(key: author.key)) {
                            LabeledContent(author.name, value: author.bookCount == 1 ? "1 book" : "\(author.bookCount) books")
                        }
                    }
                    if model.authors.count > authorLimit {
                        Button(showAllAuthors ? "Show fewer" : "Show all \(model.authors.count)") {
                            showAllAuthors.toggle()
                        }
                        .font(.footnote)
                    }
                }
            }
            Section("Books") {
                ForEach(model.list.books) { book in
                    BookLinkRow(book: book)
                        .task { await model.list.loadMoreIfNeeded(current: book) }
                }
                if model.list.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let error = model.list.error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                } else if model.list.hasLoaded && model.list.books.isEmpty {
                    Text("No books on the list.").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }
}
