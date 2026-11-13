import SwiftUI

extension EnvironmentValues {
    /// Switches to the Map tab, flies to a place (a label or heading) and
    /// opens its sheet. `MainTabs` provides it; the place term page calls it.
    @Entry var showOnMap = ShowOnMapAction { _ in }
}

/// The `showOnMap` action: a struct that compares equal (like
/// `OpenRouteAction`), so the environment does not invalidate its readers.
struct ShowOnMapAction: Equatable {
    let perform: @MainActor (String) -> Void

    @MainActor func callAsFunction(_ place: String) { perform(place) }

    static func == (lhs: ShowOnMapAction, rhs: ShowOnMapAction) -> Bool { true }
}
