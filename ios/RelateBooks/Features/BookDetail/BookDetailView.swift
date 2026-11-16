import SwiftUI

/// Book detail: every facet of the book, each linking onward.
struct BookDetailView: View {
    @State var model: BookDetailModel
    /// Lets "More like this" retry once indexing completes.
    var indexing: IndexingModel? = nil
    /// Phase 5: the note after the add flow ("Added to your library" /
    /// "Already in your library").
    var notice: AddedBookNotice? = nil
    @State private var descriptionExpanded = false
    /// Chip sections showing all values instead of the first `chipLimit`.
    @State private var expandedChips: Set<TermKind> = []
    private let chipLimit = 12
    @State private var showTagPicker = false
    @State private var noteEditing: NoteEditing?

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView("Couldn't load the book", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .loaded(nil):
                ContentUnavailableView("Book not found", systemImage: "book.closed",
                                       description: Text(model.key))
            case .loaded(let detail?):
                content(detail)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .task { await model.loadSimilar() }
        .onChange(of: indexing?.isComplete) { _, complete in
            guard complete == true, model.similar.value?.isEmpty ?? true else { return }
            Task { await model.loadSimilar(force: true) }
        }
        // An incremental embed (phase 5) does not change `isComplete`:
        // reload "More like this" when this book's vector is written.
        .onChange(of: indexing?.lastEmbeddedBookKey) { _, key in
            guard key == model.key else { return }
            Task { await model.loadSimilar(force: true) }
        }
        .sheet(isPresented: $showTagPicker) {
            TagPickerSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $noteEditing) { editing in
            NoteEditorSheet(model: model, editing: editing)
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private func content(_ book: BookDetail) -> some View {
        List {
            if let notice {
                Section { noticeRow(notice) }
            }
            Section { header(book) }
            // An app-added book has no Amazon item; its "Added in app"
            // section sits right under the header so the add flow's landing
            // screen shows the notice and the provenance together.
            if book.primaryItem == nil && book.isAppAdded {
                Section("Added in app") { addedInAppRow(book) }
            }
            userSections(model.userData ?? book.userData)
            if let item = book.primaryItem {
                Section("Amazon") { amazon(item) }
            }
            if !book.authors.isEmpty {
                Section(book.authors.count == 1 ? "Author" : "Authors") {
                    ForEach(book.authors) { author in
                        NavigationLink(value: Route.author(key: author.key)) {
                            LabeledContent(author.name, value: author.role.flatMap { $0 == "Author" ? nil : $0 } ?? "")
                        }
                    }
                }
            }
            if !book.series.isEmpty {
                Section("Series") {
                    ForEach(book.series) { s in
                        NavigationLink(value: Route.term(kind: .series, name: s.name)) {
                            LabeledContent(s.name, value: s.position.map { "#\($0)" } ?? "")
                        }
                    }
                }
            }
            if !book.awards.isEmpty {
                Section("Awards") {
                    ForEach(book.awards) { award in
                        NavigationLink(value: Route.term(kind: .award, name: award.name)) {
                            LabeledContent(award.name, value: award.year.map(String.init) ?? "")
                        }
                    }
                }
            }
            chips("Genres", book.genres, .genre)
            chips("Subjects", book.subjects, .subject)
            chips("Places", book.places, .place)
            chips("People", book.people, .person)
            chips("Eras", book.eras, .era)
            chips("Publishers", book.publishers, .publisher)
            if let description = book.description {
                Section("Description") {
                    Text(description)
                        .font(.callout)
                        .lineLimit(descriptionExpanded ? nil : 6)
                        .textSelection(.enabled)
                    Button(descriptionExpanded ? "Less" : "More") { descriptionExpanded.toggle() }
                        .font(.footnote)
                }
            }
            if !model.readingLinks.isEmpty {
                Section("Connected to your reading") {
                    ForEach(Array(model.readingLinks.enumerated()), id: \.element.id) { i, link in
                        NavigationLink(value: Route.book(key: link.connection.otherKey)) {
                            Label(link.phrase, systemImage: link.connection.kind.systemImage)
                                .font(.subheadline)
                        }
                        .accessibilityIdentifier("connected.link.\(i)")
                    }
                }
            }
            MoreLikeThisSection(similar: model.similar, links: model.similarLinks, indexingComplete: indexing?.isComplete)
            facts(book)
            if !book.items.isEmpty {
                Section(book.items.count == 1 ? "Edition on the wishlist" : "Editions on the wishlist (\(book.items.count))") {
                    ForEach(book.items) { item in editionRow(item) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(book.title)
    }

    /// Your Reading (status, dates, rating), Tags and Notes: right under the
    /// header so one screen shows them all.
    @ViewBuilder private func userSections(_ userData: BookUserData) -> some View {
        Section("Your Reading") {
            StatusControl(model: model, userData: userData)
            RatingControl(model: model, rating: userData.rating)
        }
        TagSection(model: model, userData: userData, showPicker: $showTagPicker)
        NotesSection(model: model, notes: userData.notes, editing: $noteEditing)
    }

    private func header(_ book: BookDetail) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(urls: book.imageURLs, cornerRadius: 6)
                .frame(width: 84, height: 126)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.title3.weight(.bold))
                if let subtitle = book.displaySubtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if !book.authors.isEmpty {
                    Text(book.authors.map(\.name).joined(separator: ", "))
                        .font(.subheadline)
                }
                HStack(spacing: 6) {
                    StatusBadge(status: model.userData?.status ?? book.status)
                    if book.isUnresolved {
                        Text("Amazon only").font(.caption2).foregroundStyle(.orange)
                    } else if book.isManual {
                        Text("Added manually").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let year = book.firstPublishYear {
                    Text("First published \(String(year))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// "Added to your library" (green) or "Already in your library" (blue).
    private func noticeRow(_ notice: AddedBookNotice) -> some View {
        Label(notice.text, systemImage: notice == .added ? "checkmark.circle.fill" : "books.vertical.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(notice == .added ? Color.green : Color.blue)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("book.notice")
    }

    /// Where the Amazon price would be for an app-added book (D33): the add
    /// date and how it was added, then the edition facts an ISBN import wrote.
    private func addedInAppRow(_ book: BookDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AddedInAppText.line(addedOn: book.addedOn, match: book.importMatch))
                .font(.subheadline.weight(.semibold))
            ForEach(AddedInAppText.details(book.appEdition), id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("book.addedInApp")
    }

    /// One compact row: price, format and Amazon rating, plus the link.
    private func amazon(_ item: EditionItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayPrice ?? "No price").font(.title3.weight(.semibold).monospacedDigit())
                HStack(spacing: 6) {
                    if let format = item.format { Text(format) }
                    if let rating = item.amazonRating {
                        Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.orange)
                        if let count = item.amazonReviewCount {
                            Text("(\(count.formatted()))")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let url = item.url {
                Link(destination: url) {
                    Label("Open on Amazon", systemImage: "arrow.up.right.square")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Open on Amazon")
            }
        }
    }

    @ViewBuilder private func facts(_ book: BookDetail) -> some View {
        let rows: [(String, String)] = [
            book.firstPublishYear.map { ("First published", String($0)) },
            book.pagesMedian.map { ("Pages", $0.formatted()) },
            book.editionCount.map { ("Editions (Open Library)", $0.formatted()) },
            book.olRating.map { r in
                ("Open Library rating", r.formatted(.number.precision(.fractionLength(2)))
                    + (book.olRatingCount.map { " (\($0.formatted()) ratings)" } ?? ""))
            },
            book.olWantToRead.map { ("Want to read (OL)", $0.formatted()) },
            book.olCurrentlyReading.map { ("Currently reading (OL)", $0.formatted()) },
            book.olAlreadyRead.map { ("Already read (OL)", $0.formatted()) },
            book.languages.isEmpty ? nil : ("Languages", book.languages.prefix(6).joined(separator: ", ")),
        ].compactMap { $0 }
        if !rows.isEmpty || book.url != nil {
            Section("Details") {
                ForEach(rows, id: \.0) { row in
                    LabeledContent(row.0, value: row.1)
                }
                if let url = book.url {
                    Link(destination: url) {
                        Label(book.isUnresolved ? "Open source page" : "Open on Open Library", systemImage: "safari")
                    }
                }
            }
        }
    }

    @ViewBuilder private func chips(_ title: String, _ names: [String], _ kind: TermKind) -> some View {
        if !names.isEmpty {
            let expanded = expandedChips.contains(kind) || names.count <= chipLimit
            Section("\(title) (\(names.count))") {
                FlowLayout(spacing: 6) {
                    ForEach(expanded ? names : Array(names.prefix(chipLimit)), id: \.self) { name in
                        RouteChip(title: name, route: .term(kind: kind, name: name))
                    }
                }
                .padding(.vertical, 4)
                if names.count > chipLimit {
                    Button(expanded ? "Show fewer" : "Show all \(names.count)") {
                        if expanded { expandedChips.remove(kind) } else { expandedChips.insert(kind) }
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private func editionRow(_ item: EditionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CoverImage(urls: [item.thumbnailURL, item.imageURL].compactMap { $0 })
                .frame(width: 36, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? item.asin).font(.footnote).lineLimit(2)
                HStack(spacing: 6) {
                    if let format = item.format { Text(format) }
                    if let price = item.displayPrice { Text(price).monospacedDigit() }
                    if let position = item.wishlistPosition { Text("#\(position) on list") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let url = item.url {
                    Link("Open on Amazon", destination: url).font(.caption2)
                }
            }
        }
    }
}
