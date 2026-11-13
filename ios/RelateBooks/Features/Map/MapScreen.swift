import SwiftUI

/// The Map tab: the map of place pins, place search, the count capsule,
/// the birthplace toggle, the empty state and the place sheet. All logic is
/// in `MapModel` (core).
struct MapScreen: View {
    @Bindable var model: MapModel
    let session: AppSession
    @State private var draft = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            PlaceMapView(model: model, pins: model.displayedPins, focus: model.focus,
                         selectedLabel: model.sheet?.label)
                .ignoresSafeArea()
            if model.showsEmptyState {
                emptyState
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .sheet(item: sheetBinding) { sheet in
            PlaceSheet(model: sheet, session: session) { model.deselect() }
        }
        .onChange(of: model.searchText) { _, text in
            // choose(_:) clears the search.
            if text != draft { draft = text }
        }
        .task(id: model.message) {
            guard model.message != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            model.clearMessage()
        }
    }

    private var sheetBinding: Binding<PlaceSheetModel?> {
        Binding(get: { model.sheet }, set: { if $0 == nil { model.deselect() } })
    }

    // MARK: Top: search

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search places", text: $draft)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("map.search")
                    .onChange(of: draft) { _, text in
                        if text != model.searchText { model.setSearchText(text) }
                    }
                    .onSubmit {
                        if let first = model.searchResults.first { choose(first) }
                    }
                if model.isSearching {
                    ProgressView().controlSize(.small)
                }
                if !draft.isEmpty {
                    Button {
                        draft = ""
                        model.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                    .accessibilityIdentifier("map.search.clear")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)

            if !model.searchResults.isEmpty {
                searchResults
            } else if model.showsNoSearchMatches {
                Text("No places match")
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("map.search.empty")
            }

            if let message = model.message {
                Label(message, systemImage: "mappin.slash")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("map.message")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .animation(.default, value: model.message)
    }

    private var searchResults: some View {
        let results = model.searchResults
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { i, pin in
                    Button {
                        choose(pin)
                    } label: {
                        SearchPlaceRow(pin: pin)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("map.search.result.\(i)")
                    if i < results.count - 1 {
                        Rectangle()
                            .fill(Color(uiColor: .separator))
                            .frame(height: 0.5)
                            .padding(.leading, 12)
                    }
                }
            }
        }
        .frame(height: min(CGFloat(results.count) * 70, 340))
        .scrollDismissesKeyboard(.immediately)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private func choose(_ pin: PlacePin) {
        searchFocused = false
        draft = ""
        model.choose(pin)
    }

    // MARK: Bottom: count and birthplace toggle

    private var bottomBar: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                if let error = model.error {
                    Button {
                        Task { await model.reload() }
                    } label: {
                        Label("Couldn't load places. Retry", systemImage: "arrow.clockwise")
                    }
                    .font(.footnote)
                    .accessibilityHint(error)
                } else {
                    Text(model.countText)
                        .font(.footnote.weight(.medium))
                        .accessibilityIdentifier("map.count")
                }
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("map.loading")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())

            Spacer(minLength: 8)

            Toggle(isOn: $model.showsBirthplaces) {
                Label("Birthplaces", systemImage: "person.2")
                    .font(.footnote.weight(.medium))
            }
            .toggleStyle(.button)
            .tint(.purple)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
            .accessibilityIdentifier("map.birthplacesToggle")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView("No places here", systemImage: "mappin.slash",
                               description: Text("Zoom out or search for a place."))
            .frame(maxWidth: 300, maxHeight: 220)
            .background(.regularMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 20))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("map.empty")
    }
}

/// A place search result: label, counts and the headings behind it.
private struct SearchPlaceRow: View {
    let pin: PlacePin

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pin.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(uiColor: .label))
            // Explicit label colours: hierarchical styles turn vibrant (and
            // nearly invisible) on the material card.
            Text(pin.countsText)
                .font(.caption)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
            if pin.placeNames != [pin.label] {
                Text(pin.placeNames.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
