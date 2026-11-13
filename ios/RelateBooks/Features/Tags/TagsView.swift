import SwiftUI

/// The Tags tab: every tag with its book count (count desc, then name, as
/// the query orders it). Tap opens the tag's books; swipe or long-press
/// renames, recolours or deletes.
struct TagsView: View {
    let model: TagsModel
    @State private var creating = false
    @State private var renaming: TagSummary?
    @State private var pendingDelete: TagSummary?
    @State private var draft = ""

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView("Couldn't load tags", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .loaded(let tags) where tags.isEmpty:
                ContentUnavailableView("No Tags Yet", systemImage: "tag",
                                       description: Text("Add tags from a book's page."))
            case .loaded(let tags):
                list(tags)
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    draft = ""
                    creating = true
                } label: {
                    Label("New Tag", systemImage: "plus")
                }
                .accessibilityIdentifier("tags.new")
            }
        }
        .task { await model.load() }
        .alert("New Tag", isPresented: $creating) {
            TextField("Name", text: $draft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = draft
                Task { _ = await model.create(name) }
            }
        }
        .alert("Rename Tag", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }), presenting: renaming) { tag in
            TextField("Name", text: $draft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = draft
                Task { _ = await model.rename(tag, to: name) }
            }
        }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.name)”?" } ?? "Delete tag?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete) { tag in
            Button("Delete", role: .destructive) {
                Task { await model.delete(tag) }
            }
        } message: { tag in
            Text(tag.bookCount == 1 ? "It will be removed from 1 book." : "It will be removed from \(tag.bookCount) books.")
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private func list(_ tags: [TagSummary]) -> some View {
        List {
            ForEach(tags) { tag in
                NavigationLink(value: Route.tag(name: tag.name)) {
                    HStack {
                        Circle().fill(tag.color?.color ?? .gray).frame(width: 10, height: 10)
                        Text(tag.name)
                        Spacer()
                        Text("\(tag.bookCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(tag.name) (\(tag.bookCount))")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("tags.row.\(tag.name)")
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = tag }
                    Button("Rename", systemImage: "pencil") {
                        draft = tag.name
                        renaming = tag
                    }
                    .tint(.indigo)
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") {
                        draft = tag.name
                        renaming = tag
                    }
                    Menu("Color") {
                        ForEach(TagColor.allCases) { color in
                            Button {
                                Task { await model.setColor(tag, color) }
                            } label: {
                                checkLabel(color.label, on: tag.color == color)
                            }
                        }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = tag }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load() }
    }
}
