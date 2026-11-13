import SwiftUI

/// Which note the editor sheet is showing.
enum NoteEditing: Identifiable {
    case new
    case existing(BookNote)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let note): note.id
        }
    }
}

/// The book's notes, newest first, then "Add Note". Tap edits, swipe
/// deletes. The editor sheet is presented by `BookDetailView`.
struct NotesSection: View {
    let model: BookDetailModel
    let notes: [BookNote]
    @Binding var editing: NoteEditing?

    var body: some View {
        Section {
            ForEach(notes) { note in
                Button {
                    editing = .existing(note)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.text)
                            .font(.callout)
                            .lineLimit(6)
                            .multilineTextAlignment(.leading)
                        Text(timestamp(note))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("note.row")
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await model.deleteNote(id: note.id) }
                    }
                }
            }
            // Last, so the newest note sits right under the section header.
            Button {
                editing = .new
            } label: {
                Label("Add Note", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("note.add")
        } header: {
            Text(notes.isEmpty ? "Notes" : "Notes (\(notes.count))")
        }
    }

    private func timestamp(_ note: BookNote) -> String {
        note.wasEdited
            ? "Edited \(note.updatedOn.formatted(date: .abbreviated, time: .shortened))"
            : "Added \(note.createdOn.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// Plain-text editor for a new or existing note. Save awaits the write and
/// stays open with the error if it fails, so typed text is never lost.
struct NoteEditorSheet: View {
    let model: BookDetailModel
    let editing: NoteEditing
    @State private var text: String
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    private let original: String

    init(model: BookDetailModel, editing: NoteEditing) {
        self.model = model
        self.editing = editing
        let initial: String
        if case .existing(let note) = editing { initial = note.text } else { initial = "" }
        self.original = initial
        _text = State(initialValue: initial)
    }

    private var existingID: String? {
        if case .existing(let note) = editing { return note.id }
        return nil
    }

    private var isNew: Bool { existingID == nil }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("note.editor.text")
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                }
            }
            .navigationTitle(isNew ? "New Note" : "Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("note.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                        .accessibilityIdentifier("note.editor.save")
                }
                if !isNew {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Delete Note", role: .destructive) { confirmDelete = true }
                            .accessibilityIdentifier("note.editor.delete")
                    }
                }
            }
            .confirmationDialog("Delete this note?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let id = existingID else { return }
                    Task {
                        await model.deleteNote(id: id)
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(text != original)
    }

    private func save() {
        // Set synchronously so a second tap before the Task starts cannot
        // queue a second save (two addNote calls with different UUIDs).
        guard !saving else { return }
        saving = true
        Task {
            if await model.saveNote(id: existingID, text: text) {
                dismiss()
            } else {
                error = model.actionError
                model.actionError = nil
            }
            saving = false
        }
    }
}
