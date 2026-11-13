import SwiftUI

/// One list row: cover, title (+ English item title when it differs),
/// authors, format, status badge and price (or "Added in app").
struct BookRow: View {
    let book: BookSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(urls: book.imageURLs)
                .frame(width: 48, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let subtitle = book.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(book.authorLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusBadge(status: book.status)
                    if let rating = book.myRating {
                        Label("\(rating)", systemImage: "star.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(rating == 1 ? "Your rating: 1 star" : "Your rating: \(rating) stars")
                    }
                    if let format = book.format {
                        Text(format)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if book.itemCount > 1 {
                        Text("\(book.itemCount) editions")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    if let trailing = book.trailingText {
                        if book.displayPrice != nil {
                            Text(trailing)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.primary)
                        } else {
                            // "Added in app" (phase 5): no Amazon price.
                            Text(trailing)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A row that pushes the book detail.
struct BookLinkRow: View {
    let book: BookSummary

    var body: some View {
        NavigationLink(value: Route.book(key: book.key)) {
            BookRow(book: book)
        }
    }
}
