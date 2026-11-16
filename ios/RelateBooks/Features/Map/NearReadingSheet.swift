import SwiftUI

/// The Map tab's "Near your reading" list: unread books set at or near the
/// places of books the user has read. Choosing a place closes the sheet and
/// flies the map there. All logic is in `NearReadingModel` (core).
struct NearReadingSheet: View {
    let model: NearReadingModel
    let choose: (NearbyReading) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Near Your Reading")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("nearReading.done")
                    }
                }
        }
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Couldn't load places", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .loaded(let places) where places.isEmpty:
            ContentUnavailableView {
                Label("Nothing nearby yet", systemImage: "mappin.and.ellipse")
            } description: {
                Text("When you mark a book as read, unread books set in the same place or within 250 km of it are listed here.")
            }
            .accessibilityIdentifier("nearReading.empty")
        case .loaded(let places):
            List {
                Section {
                    ForEach(Array(places.enumerated()), id: \.element.id) { i, place in
                        Button {
                            choose(place)
                        } label: {
                            NearbyPlaceRow(place: place)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("nearReading.place.\(i)")
                    }
                } footer: {
                    Text("Unread books set where a book you read is set, or within 250 km. Countries and other places on many books are left out.")
                }
            }
            .accessibilityIdentifier("nearReading.list")
        }
    }
}

private struct NearbyPlaceRow: View {
    let place: NearbyReading

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(place.label)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(place.bookCount == 1 ? "1 book" : "\(place.bookCount) books")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(place.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(titles)
                .font(.caption)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var titles: String {
        let shown = place.books.map(\.title).joined(separator: " · ")
        let more = place.bookCount - place.books.count
        return more > 0 ? "\(shown) + \(more) more" : shown
    }
}
