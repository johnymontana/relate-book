import SwiftUI

extension View {
    /// Leading swipe: Read / Reading (whichever is not current). Trailing
    /// swipe: back to Want. Button titles are exactly the status short labels.
    func statusSwipeActions(current: ReadingStatus, set: @escaping (ReadingStatus) -> Void) -> some View {
        self
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                ForEach([ReadingStatus.read, .reading].filter { $0 != current }) { status in
                    Button {
                        set(status)
                    } label: {
                        Label(status.shortLabel, systemImage: status == .read ? "checkmark.circle" : "book")
                    }
                    .tint(status == .read ? .green : .orange)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if current != .want {
                    Button {
                        set(.want)
                    } label: {
                        Label(ReadingStatus.want.shortLabel, systemImage: "bookmark")
                    }
                    .tint(.blue)
                }
            }
    }
}
