import SwiftUI

/// One tag's books (title order), with status swipe actions. If the tag is
/// renamed or deleted elsewhere, the list reloads empty on return.
struct TagBooksView: View {
    @State var model: TagBooksModel

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TAG")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(model.name).font(.title3.weight(.bold))
                    if let total = model.total {
                        Text(total == 1 ? "1 book" : "\(total) books")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Books") {
                ForEach(model.list.books) { book in
                    BookLinkRow(book: book)
                        .statusSwipeActions(current: book.status) { status in
                            Task { await model.setStatus(key: book.key, to: status) }
                        }
                        .task { await model.list.loadMoreIfNeeded(current: book) }
                }
                if model.list.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let error = model.list.error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                } else if model.list.hasLoaded && model.list.books.isEmpty {
                    Text("No books with this tag.").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onAppear { Task { await model.reloadIfNeeded() } }
        .alert("Couldn't save", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }
}
