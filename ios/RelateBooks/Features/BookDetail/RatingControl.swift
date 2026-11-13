import SwiftUI

/// Five tappable stars. Tapping the current rating clears it.
struct RatingControl: View {
    let model: BookDetailModel
    let rating: Int?

    var body: some View {
        LabeledContent("Your rating") {
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { n in
                    Button {
                        Task { await model.setRating(n == rating ? nil : n) }
                    } label: {
                        Image(systemName: n <= (rating ?? 0) ? "star.fill" : "star")
                            .foregroundStyle(.orange)
                            .imageScale(.large)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("rating.star.\(n)")
                    .accessibilityLabel(n == 1 ? "1 star" : "\(n) stars")
                    .accessibilityAddTraits(n <= (rating ?? 0) ? .isSelected : [])
                }
            }
        }
    }
}
