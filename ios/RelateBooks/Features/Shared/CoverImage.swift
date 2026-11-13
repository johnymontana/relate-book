import SwiftUI

/// Loads the first URL that works from a preference-ordered list (Open
/// Library cover, then the Amazon image), else a placeholder.
struct CoverImage: View {
    let urls: [URL]
    var cornerRadius: CGFloat = 4
    @State private var index = 0

    var body: some View {
        // A clear rectangle takes exactly the proposed frame; the image fills
        // it as an overlay and is clipped to it (a bare fill image would
        // report its own, larger size and overflow the caller's frame).
        Rectangle().fill(.clear).overlay {
            if index < urls.count {
                AsyncImage(url: urls[index], transaction: Transaction(animation: .easeOut(duration: 0.15))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure(let error):
                        // A load cancelled by scrolling away is not a bad URL:
                        // only real failures fall back to the next candidate.
                        placeholder.onAppear { if !CoverImage.isCancellation(error) { index += 1 } }
                    default:
                        placeholder.overlay(ProgressView().controlSize(.mini))
                    }
                }
                .id(index)
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(Rectangle())
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.quaternary, lineWidth: 0.5))
        .accessibilityHidden(true)
        .onChange(of: urls) { index = 0 }
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .overlay(Image(systemName: "book.closed").foregroundStyle(.tertiary))
    }
}
