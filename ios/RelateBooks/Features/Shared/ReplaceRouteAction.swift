import SwiftUI

extension EnvironmentValues {
    /// Replaces the top of the enclosing NavigationStack's path with a route
    /// (phase 5: the Add Book screen replaces itself with the added book's
    /// detail, so Back returns to the Library list). `LibraryRoot` pops and
    /// pushes; the other stacks provide a plain push.
    @Entry var replaceRoute = ReplaceRouteAction { _ in }
}

/// The `replaceRoute` action: a struct that compares equal (like
/// `OpenRouteAction`), so the environment does not invalidate its readers.
struct ReplaceRouteAction: Equatable {
    let perform: @MainActor (Route) -> Void

    @MainActor func callAsFunction(_ route: Route) { perform(route) }

    /// One action per NavigationStack; the stack's path binding does the work.
    static func == (lhs: ReplaceRouteAction, rhs: ReplaceRouteAction) -> Bool { true }
}
