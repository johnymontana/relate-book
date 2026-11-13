import SwiftUI

/// The Search tab: one text field, hybrid results with a reason per row,
/// an empty state with example queries, and a thin banner while the
/// on-device index is being built. All logic is in `SearchModel` (core).
struct SearchView: View {
    let model: SearchModel
    let indexing: IndexingModel
    let userData: UserDataController
    /// Shows the always-on `index.status` line (`--wait-for-index`).
    var showsStatusLine = false
    @State private var draft: String
    @State private var tagNames: [String] = []

    init(model: SearchModel, indexing: IndexingModel, userData: UserDataController, showsStatusLine: Bool = false) {
        self.model = model
        self.indexing = indexing
        self.userData = userData
        self.showsStatusLine = showsStatusLine
        _draft = State(initialValue: model.text)
    }

    var body: some View {
        content
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsStatusLine { statusLine }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            .onAppear {
                Task { await model.rerunIfNeeded() }
                model.prepareEmbedder()
                indexing.resume()
                Task { await loadTags() }
            }
            .onChange(of: model.text) { _, text in
                // A launch `--search` (or any programmatic submit) fills the field.
                if text != draft { draft = text }
            }
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Describe a book, or type a title or author", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("search.field")
                    .onChange(of: draft) { _, text in
                        if text != model.text { model.setText(text) }
                    }
                    .onSubmit { model.submit(draft) }
                if !draft.isEmpty {
                    Button {
                        draft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                    .accessibilityIdentifier("search.clear")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            if indexing.progress.phase == .indexing {
                IndexingBanner(progress: indexing.progress)
            }
            if isUnavailable {
                Text("Semantic search unavailable — showing keyword matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("index.unavailable")
            }
        }
        .background(.bar)
    }

    private var isUnavailable: Bool {
        switch indexing.progress.phase {
        case .unavailable, .failed: true
        default: false
        }
    }

    private var statusLine: some View {
        Text(indexing.progress.statusLabel)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 4)
            .background(.bar)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(indexing.progress.statusLabel)
            .accessibilityIdentifier("index.status")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            emptyState
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .loaded(let response) where response.isEmpty:
            ContentUnavailableView.search(text: response.query)
        case .loaded(let response):
            results(response)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Search your books", systemImage: "sparkle.magnifyingglass")
        } description: {
            Text("Describe what you remember, or type a title or author. Notes you wrote are searched too.")
        } actions: {
            VStack(spacing: 8) {
                ForEach(Array(SearchModel.exampleQueries.enumerated()), id: \.offset) { i, query in
                    Button(query) {
                        draft = query
                        model.submit(query)
                    }
                    .font(.callout)
                    .accessibilityIdentifier("search.example.\(i)")
                }
            }
        }
    }

    private func results(_ response: SearchResponse) -> some View {
        List {
            Section {
                ForEach(Array(response.results.enumerated()), id: \.element.id) { i, result in
                    NavigationLink(value: Route.book(key: result.book.key)) {
                        SearchResultRow(result: result)
                    }
                    .accessibilityIdentifier("search.result.\(i)")
                }
            } header: {
                Text(header(response))
                    .font(.footnote)
                    .textCase(nil)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    private func header(_ response: SearchResponse) -> String {
        let n = response.results.count
        var text = n == 1 ? "1 result" : "\(n) results"
        if indexing.isIndexing {
            let p = indexing.progress
            text += " · Semantic results cover \(p.embeddedBooks.formatted()) of \(p.totalBooks.formatted()) books so far"
        }
        return text
    }

    // MARK: Filters

    private var filterMenu: some View {
        Menu {
            Picker("Status", selection: Binding(
                get: { model.filter.status },
                set: { status in setFilter(SearchFilter(status: status, tag: model.filter.tag)) })) {
                Text("Any status").tag(ReadingStatus?.none)
                ForEach(ReadingStatus.allCases) { status in
                    Text(status.shortLabel).tag(ReadingStatus?.some(status))
                }
            }
            Picker("Tag", selection: Binding(
                get: { model.filter.tag },
                set: { tag in setFilter(SearchFilter(status: model.filter.status, tag: tag)) })) {
                Text("Any tag").tag(String?.none)
                ForEach(tagNames, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
        } label: {
            Label("Filter", systemImage: model.filter.isEmpty
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("search.filter")
    }

    private func setFilter(_ filter: SearchFilter) {
        Task { await model.setFilter(filter) }
    }

    private func loadTags() async {
        tagNames = (try? await userData.tags().map(\.name)) ?? tagNames
    }
}
