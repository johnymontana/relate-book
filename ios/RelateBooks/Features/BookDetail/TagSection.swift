import SwiftUI

/// The book's tags as chips, plus "Add Tag". The picker sheet is
/// presented by `BookDetailView` (a sheet on a List section is unreliable).
struct TagSection: View {
    let model: BookDetailModel
    let userData: BookUserData
    @Binding var showPicker: Bool

    var body: some View {
        Section("Tags") {
            // Chips and "Add Tag" share one wrapping row (borderless buttons,
            // so each is its own tap target inside the List row).
            FlowLayout(spacing: 6) {
                ForEach(userData.tags) { tag in
                    TagChip(tag: tag) { Task { await model.removeTag(tag.name) } }
                }
                Button {
                    showPicker = true
                } label: {
                    // Not a Label: inside a List row a Label takes the row's
                    // icon-column layout and measures wrongly in FlowLayout.
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add Tag")
                    }
                    .font(.footnote)
                    .fixedSize()
                    .padding(.vertical, 5)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add Tag")
                .accessibilityIdentifier("tag.add")
            }
            .padding(.vertical, 4)
        }
    }
}

/// Type to filter or create; tap a tag to add or remove it.
struct TagPickerSheet: View {
    let model: BookDetailModel
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var showCreate: Bool {
        !trimmed.isEmpty && !model.allTags.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private var filteredTags: [TagSummary] {
        let sorted = model.allTags.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return trimmed.isEmpty ? sorted : sorted.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private func applied(_ tag: TagSummary) -> Bool {
        model.userData?.tags.contains { $0.name.caseInsensitiveCompare(tag.name) == .orderedSame } ?? false
    }

    private func submit() {
        let name = trimmed
        guard !name.isEmpty else { return }
        Task {
            await model.addTag(name)
            query = ""
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("New or existing tag", text: $query)
                        .accessibilityIdentifier("tag.picker.field")
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { submit() }
                    if showCreate {
                        Button("Create “\(trimmed)”", systemImage: "plus.circle") { submit() }
                            .accessibilityIdentifier("tag.picker.create")
                    }
                }
                if !filteredTags.isEmpty {
                    Section("Tags") {
                        ForEach(filteredTags) { tag in
                            Button {
                                Task { await model.toggleTag(tag.name) }
                            } label: {
                                HStack {
                                    Circle().fill(tag.color?.color ?? .gray).frame(width: 10, height: 10)
                                    Text(tag.name).foregroundStyle(.primary)
                                    Spacer()
                                    if applied(tag) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .accessibilityIdentifier("tag.picker.option.\(tag.name)")
                            .accessibilityAddTraits(applied(tag) ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("tag.picker.done")
                }
            }
            .task { await model.loadAllTags() }
            // The detail screen's alert cannot present over this sheet, so
            // errors from the picker show here.
            .alert("Couldn't save", isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
        }
    }
}
