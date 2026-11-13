import SwiftUI

/// The Library tab: searchable, sortable, filterable, infinitely scrolling.
struct LibraryView: View {
    let model: LibraryModel
    @State private var searchText = ""
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        List {
            Section {
                ForEach(model.list.books) { book in
                    BookLinkRow(book: book)
                        .statusSwipeActions(current: book.status) { status in
                            Task { await model.setStatus(key: book.key, to: status) }
                        }
                        .task { await model.list.loadMoreIfNeeded(current: book) }
                }
                footer
            } header: {
                header
            }
        }
        .listStyle(.plain)
        .onAppear { Task { await model.reloadIfNeeded() } }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilterBar(model: model)
                .background(.bar)
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Title or author")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onChange(of: searchText) { _, text in model.setSearchText(text) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: Binding(
                        get: { model.sort },
                        set: { newSort in Task { await model.setSort(newSort) } })) {
                        ForEach(LibrarySort.allCases) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            // Phase 5: the Add Book screen (Search / Scan / Manual).
            ToolbarItem(placement: .topBarTrailing) {
                Button { openRoute(.addBook) } label: {
                    Label("Add Book", systemImage: "plus")
                }
                .accessibilityIdentifier("library.add")
            }
        }
        .task { await model.start() }
        .refreshable { await model.reload() }
        .alert("Couldn't save", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    @ViewBuilder private var header: some View {
        if let total = model.total {
            HStack {
                Text(total == 1 ? "1 book" : "\(total.formatted()) books")
                if let all = model.totalBooks, all != total {
                    Text("of \(all.formatted())").foregroundStyle(.tertiary)
                }
                Spacer()
                Text("by \(model.sort.label.lowercased())").foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
    }

    @ViewBuilder private var footer: some View {
        if let error = model.list.error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
        } else if model.list.isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }
        } else if model.list.hasLoaded && model.list.books.isEmpty {
            ContentUnavailableView("No matching books", systemImage: "magnifyingglass",
                                   description: Text("Try other filters or search text."))
        }
    }
}

/// Horizontally scrolling filter chips: status, format, genre, tag, unresolved.
struct FilterBar: View {
    let model: LibraryModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.filter.activeCount > 0 {
                    Button {
                        Task { await model.clearFilters() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Clear filters")
                    .buttonStyle(.borderless)
                }
                Menu {
                    ForEach(ReadingStatus.allCases) { status in
                        Button {
                            Task { await model.toggleStatus(status) }
                        } label: {
                            checkLabel(status.label, on: model.filter.status == status)
                        }
                    }
                } label: {
                    chip(model.filter.status?.label ?? "Status", active: model.filter.status != nil)
                }
                Menu {
                    ForEach(model.formats) { facet in
                        Button {
                            Task { await model.toggleFormat(facet.name) }
                        } label: {
                            checkLabel("\(facet.name) (\(facet.count))", on: model.filter.format == facet.name)
                        }
                    }
                } label: {
                    chip(model.filter.format ?? "Format", active: model.filter.format != nil)
                }
                Menu {
                    ForEach(model.genres) { facet in
                        Button {
                            Task { await model.toggleGenre(facet.name) }
                        } label: {
                            checkLabel("\(facet.name) (\(facet.count))", on: model.filter.genre == facet.name)
                        }
                    }
                } label: {
                    chip(model.filter.genre ?? "Genre", active: model.filter.genre != nil)
                }
                Menu {
                    if model.tags.isEmpty {
                        Text("No tags yet")
                    }
                    ForEach(model.tags) { tag in
                        Button {
                            Task { await model.toggleTag(tag.name) }
                        } label: {
                            checkLabel("\(tag.name) (\(tag.bookCount))", on: model.filter.tag == tag.name)
                        }
                    }
                } label: {
                    chip(model.filter.tag ?? "Tag", active: model.filter.tag != nil)
                }
                .accessibilityIdentifier("filter.tag")
                Button {
                    Task { await model.toggleUnresolved() }
                } label: {
                    chip("Unresolved", active: model.filter.unresolvedOnly, menu: false)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, active: Bool, menu: Bool = true) -> some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            if menu { Image(systemName: "chevron.down").font(.caption2) }
        }
        .font(.footnote.weight(active ? .semibold : .regular))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(active ? Color.white : Color.primary)
        .background(active ? Color.accentColor : Color.secondary.opacity(0.14), in: Capsule())
    }
}
