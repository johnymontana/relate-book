import AVFoundation
import SwiftUI

/// The Add Book screen (phase 5, D-I): a segmented Search / Scan / Manual
/// control over one `AddBookModel`. Pushed on the Library stack; when the
/// flow finishes it replaces itself with the book's detail (D23), so Back
/// returns to the Library list.
struct AddBookView: View {
    /// Owned as state, like `BookDetailView`: `RouteDestination` re-runs and
    /// builds a new model, but `@State` keeps the first, so a re-render
    /// never loses an import (`AddBookModel.init` has no side effects).
    @State private var model: AddBookModel
    @State private var didNavigate = false
    @Environment(\.replaceRoute) private var replaceRoute

    init(model: AddBookModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $model.mode) {
                ForEach(AddBookModel.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("addBook.mode")
            .disabled(model.isBusy)

            Group {
                switch model.mode {
                case .search: AddBookSearchSection(model: model)
                case .scan: AddBookScanSection(model: model)
                case .manual: AddBookManualSection(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(model.isBusy)
        }
        .overlay {
            if let text = model.progressText {
                ImportProgressView(text: text)
            } else if let message = model.errorText {
                ImportErrorCard(message: message, retry: { model.retry() }, dismiss: { model.reset() })
            }
        }
        .animation(.default, value: model.isBusy)
        .navigationTitle("Add Book")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.phase) { _, phase in finishIfDone(phase) }
        .onAppear { finishIfDone(model.phase) }
        // Leaving (or switching tabs) cancels a lookup that has not started
        // saving; once saving starts the pipeline runs to the end (D24).
        .onDisappear { model.cancel() }
    }

    /// On `.finished`, replace this screen with the book's detail, once.
    private func finishIfDone(_ phase: AddBookModel.Phase) {
        guard !didNavigate, case .finished(let result) = phase else { return }
        didNavigate = true
        replaceRoute(.addedBook(key: result.key, notice: result.alreadyInLibrary ? .alreadyInLibrary : .added))
    }
}

// MARK: - Search

/// Open Library search as you type (debounced in the model; 3+ letters).
struct AddBookSearchSection: View {
    let model: AddBookModel

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title, author or ISBN", text: Binding(
                get: { model.searchText },
                set: { model.setSearchText($0) }))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { model.submitSearch() }
                .accessibilityIdentifier("addBook.search.field")
                .padding(.horizontal)
                .padding(.bottom, 8)
            content
        }
        .confirmationDialog(
            "Add “\(model.pendingConfirmation?.title ?? "")”?",
            isPresented: Binding(
                get: { model.pendingConfirmation != nil },
                set: { if !$0 { model.cancelPending() } }),
            titleVisibility: .visible,
            presenting: model.pendingConfirmation
        ) { doc in
            Button("Add to Library") {
                // The dialog may clear `pendingConfirmation` as it dismisses;
                // set it again so the confirm always imports this row.
                model.pendingConfirmation = doc
                model.confirmPending()
            }
            .accessibilityIdentifier("addBook.confirm")
            Button("Cancel", role: .cancel) { model.cancelPending() }
        } message: { doc in
            Text([doc.authorLine, doc.firstPublishYear.map(String.init)].compactMap { $0 }.joined(separator: " · "))
        }
    }

    @ViewBuilder private var content: some View {
        switch model.searchResults {
        case .idle:
            hint("Type at least 3 letters to search Open Library.", id: "addBook.search.hint")
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { model.submitSearch() }
                    .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let docs) where docs.isEmpty:
            hint("No matches on Open Library.", id: "addBook.search.empty")
        case .loaded(let docs):
            List {
                Section {
                    ForEach(Array(docs.enumerated()), id: \.element.id) { i, doc in
                        Button { model.choose(doc) } label: {
                            AddBookResultRow(doc: doc, inLibrary: model.inLibraryKeys.contains(doc.key))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("addBook.result.\(i)")
                    }
                } footer: {
                    Link("Results from Open Library", destination: URL(string: "https://openlibrary.org")!)
                        .font(.caption)
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func hint(_ text: String, id: String) -> some View {
        VStack {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 40)
                .accessibilityIdentifier(id)
            Spacer()
        }
    }
}

/// One Open Library result: cover, title, authors, first year, and an
/// "In your library" badge for a work the store already has.
struct AddBookResultRow: View {
    let doc: OLSearchDoc
    let inLibrary: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(urls: [doc.coverURL].compactMap { $0 })
                .frame(width: 40, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(doc.authorLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let year = doc.firstPublishYear {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if inLibrary {
                Label("In your library", systemImage: "books.vertical")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scan

/// The camera scanner (when the device supports it) and, always, a typed
/// ISBN field: the simulator has no DataScanner, so the UI tests type.
struct AddBookScanSection: View {
    let model: AddBookModel
    @State private var camera = ScannerAvailability.current
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // One handler for the camera and the DEBUG simulated scan (D28).
        let onPayload: @MainActor (String) -> Void = { model.didScan(payload: $0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch camera {
                case .available:
                    ISBNScannerView(isActive: model.isScannerActive, onPayload: onPayload)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("addBook.scanner")
                case .needsPermission:
                    cameraCard("Scan a barcode", systemImage: "barcode.viewfinder",
                               message: "Allow camera access to scan, or type the ISBN below.") {
                        Button("Allow Camera") {
                            Task {
                                _ = await AVCaptureDevice.requestAccess(for: .video)
                                camera = ScannerAvailability.current
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .denied:
                    cameraCard("Camera access is off", systemImage: "camera.badge.ellipsis",
                               message: "Turn on camera access for RelateBooks in Settings to scan, or type the ISBN below.") {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(.bordered)
                    }
                case .unsupported:
                    ContentUnavailableView("Camera scanning unavailable", systemImage: "barcode.viewfinder",
                                           description: Text("Type the ISBN from the back cover or the copyright page."))
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("addBook.scanner.unavailable")
                }
                if let message = model.scannerMessage {
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("addBook.scanner.message")
                }
                Text("Type an ISBN")
                    .font(.headline)
                    .padding(.top, 4)
                TextField("978…", text: Binding(
                    get: { model.isbnText },
                    set: { model.setISBNText($0) }))
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { model.submitISBN() }
                    .accessibilityIdentifier("addBook.isbn.field")
                if let message = model.isbnValidation.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(model.isbnValidation.isValid ? Color.green : Color.secondary)
                        .accessibilityIdentifier("addBook.isbn.message")
                }
                Button {
                    model.submitISBN()
                } label: {
                    Text("Look Up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isbnValidation.isValid)
                .accessibilityIdentifier("addBook.isbn.submit")
            }
            .padding(.horizontal)
            .padding(.top, 4)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            camera = ScannerAvailability.current
            // DEBUG --simulate-scan: handed out once by the model.
            if let payload = model.takeSimulatedScan() { onPayload(payload) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings with camera access changed.
            if phase == .active { camera = ScannerAvailability.current }
        }
    }

    /// A camera card (permission states), sized like the unavailable card.
    private func cameraCard(_ title: String, systemImage: String, message: String,
                            @ViewBuilder action: () -> some View) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action()
        }
        .padding()
        .frame(maxWidth: .infinity)
        .frame(minHeight: 200)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("addBook.scanner.permission")
    }
}

// MARK: - Manual

/// Title and authors only; no Open Library lookup.
struct AddBookManualSection: View {
    @Bindable var model: AddBookModel

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $model.manualTitle)
                    .accessibilityIdentifier("addBook.manual.title")
                TextField("Authors (comma-separated)", text: $model.manualAuthors)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("addBook.manual.authors")
            } footer: {
                Text("No Open Library lookup: only the title and authors are saved.")
            }
            Section {
                Button {
                    model.submitManual()
                } label: {
                    Text("Add Book").frame(maxWidth: .infinity)
                }
                .disabled(!model.canSubmitManual)
                .accessibilityIdentifier("addBook.manual.submit")
            }
        }
    }
}

// MARK: - Progress and errors

/// The card shown while importing: a spinner and the step label.
struct ImportProgressView: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(text)
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("addBook.progress.text")
            }
            .padding(24)
            .frame(minWidth: 220)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("addBook.progress")
        }
    }
}

/// The card shown when an import failed: the message, Retry and Dismiss.
struct ImportErrorCard: View {
    let message: String
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Dismiss", action: dismiss)
                        .buttonStyle(.bordered)
                    Button("Retry", action: retry)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("addBook.retry")
                }
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("addBook.error")
        }
    }
}
