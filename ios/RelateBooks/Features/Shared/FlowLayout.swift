import SwiftUI

/// Wraps children onto as many lines as needed (subject chips etc.).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                let nextY = current.y + current.height + spacing
                rows.append(current)
                current = Row(y: nextY)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

extension EnvironmentValues {
    /// Pushes a route onto the enclosing NavigationStack's path. Used where a
    /// NavigationLink inside a List row would draw a disclosure chevron.
    @Entry var openRoute = OpenRouteAction { _ in }
}

/// The `openRoute` action. A struct that compares equal, not a bare closure,
/// so storing it in the environment does not invalidate every reader on
/// each update (a bare closure is never comparable).
struct OpenRouteAction: Equatable {
    let perform: @MainActor (Route) -> Void

    @MainActor func callAsFunction(_ route: Route) { perform(route) }

    /// One action per NavigationStack; the stack's path binding does the work.
    static func == (lhs: OpenRouteAction, rhs: OpenRouteAction) -> Bool { true }
}

/// A tappable chip that pushes a route.
struct RouteChip: View {
    let title: String
    let route: Route
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        Button {
            openRoute(route)
        } label: {
            Text(title)
                .font(.footnote)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.fill.tertiary, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
