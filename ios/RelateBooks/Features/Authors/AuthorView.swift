import SwiftUI

/// Author page: photo, dates, bio, birthplace, citizenship, awards, links,
/// and the author's books on the list.
struct AuthorView: View {
    @State var model: AuthorModel

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView("Couldn't load the author", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .loaded(nil):
                ContentUnavailableView("Author not found", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text(model.key))
            case .loaded(let loaded?):
                content(loaded.detail, books: loaded.books)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private func content(_ author: AuthorDetail, books: [BookSummary]) -> some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    CoverImage(urls: author.imageURLs, cornerRadius: 8)
                        .frame(width: 96, height: 120)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(author.name).font(.title3.weight(.bold))
                        if let lifespan = author.lifespan {
                            Text(lifespan).font(.caption).foregroundStyle(.secondary)
                        }
                        if !author.occupations.isEmpty {
                            Text(author.occupations.prefix(4).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(author.bookCount == 1 ? "1 book on the list" : "\(author.bookCount) books on the list")
                            .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Books on the list") {
                ForEach(books) { book in BookLinkRow(book: book) }
            }
            if let bio = author.bio {
                Section("Biography") {
                    Text(bio).font(.callout).lineLimit(12).textSelection(.enabled)
                }
            }
            if !author.bornIn.isEmpty || !author.citizenOf.isEmpty {
                Section("Origins") {
                    ForEach(author.bornIn, id: \.self) { place in
                        NavigationLink(value: Route.term(kind: .place, name: place)) {
                            LabeledContent("Born in", value: place)
                        }
                    }
                    ForEach(author.citizenOf, id: \.self) { country in
                        NavigationLink(value: Route.term(kind: .country, name: country)) {
                            LabeledContent("Citizen of", value: country)
                        }
                    }
                }
            }
            if !author.awards.isEmpty {
                Section("Awards (\(author.awards.count))") {
                    ForEach(author.awards) { award in
                        NavigationLink(value: Route.term(kind: .award, name: award.name)) {
                            LabeledContent(award.name, value: award.year.map(String.init) ?? "")
                        }
                    }
                }
            }
            let links: [(String, URL)] = [
                author.wikipediaURL.map { ("Wikipedia", $0) },
                author.wikidataURL.map { ("Wikidata", $0) },
                author.openLibraryURL.map { ("Open Library", $0) },
            ].compactMap { $0 }
            if !links.isEmpty {
                Section("Links") {
                    ForEach(links, id: \.0) { link in
                        Link(destination: link.1) { Label(link.0, systemImage: "safari") }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(author.name)
    }
}
