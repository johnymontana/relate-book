import SwiftUI

/// Root: opens the store, then shows the tabs (Library, Tags, Search, Map).
struct ContentView: View {
    let environment: AppEnvironment

    var body: some View {
        switch environment.state {
        case .loading:
            ProgressView("Opening library…")
        case .ready(let session):
            MainTabs(session: session, launchOptions: environment.launchOptions)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't open the library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await environment.start() } }
            }
        }
    }
}

/// The tab bar. `--open-tab` picks the first tab (`--search` and
/// `--map-place` imply theirs); launch routes always go onto the Library
/// stack. `showOnMap` (the place term page's "Show on map") switches to the
/// Map tab and flies there.
struct MainTabs: View {
    let session: AppSession
    let launchOptions: LaunchOptions
    @State private var tab: AppTab

    init(session: AppSession, launchOptions: LaunchOptions) {
        self.session = session
        self.launchOptions = launchOptions
        _tab = State(initialValue: launchOptions.initialTab ?? .library)
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                LibraryRoot(session: session, initialRoutes: launchOptions.routes)
            }
            Tab("Tags", systemImage: "tag", value: AppTab.tags) {
                TagsRoot(session: session)
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                SearchRoot(session: session, launchOptions: launchOptions)
            }
            Tab("Map", systemImage: "map", value: AppTab.map) {
                MapRoot(session: session, launchOptions: launchOptions)
            }
        }
        .environment(\.showOnMap, ShowOnMapAction { place in
            tab = .map
            Task { await session.map.focus(on: place) }
        })
    }
}

/// The Library tab's NavigationStack. Launch routes become the initial path.
struct LibraryRoot: View {
    let session: AppSession
    @State private var path: [Route]

    init(session: AppSession, initialRoutes: [Route]) {
        self.session = session
        _path = State(initialValue: initialRoutes)
    }

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(model: session.library)
                .navigationDestination(for: Route.self) { route in
                    RouteDestination(route: route, session: session)
                }
        }
        .environment(\.openRoute, OpenRouteAction { route in path.append(route) })
        // The Add Book screen replaces itself with the added book (D23).
        .environment(\.replaceRoute, ReplaceRouteAction { route in
            if !path.isEmpty { path.removeLast() }
            path.append(route)
        })
    }
}

/// The Tags tab's NavigationStack.
struct TagsRoot: View {
    let session: AppSession
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            TagsView(model: session.tags)
                .navigationDestination(for: Route.self) { route in
                    RouteDestination(route: route, session: session)
                }
        }
        .environment(\.openRoute, OpenRouteAction { route in path.append(route) })
        .environment(\.replaceRoute, ReplaceRouteAction { route in path.append(route) })
    }
}

/// The Search tab's NavigationStack. A launch `--search` runs once on first
/// appear. When indexing completes, whatever was searched (with a partial
/// index) runs again.
struct SearchRoot: View {
    let session: AppSession
    let launchOptions: LaunchOptions
    @State private var path: [Route] = []
    @State private var didLaunchSearch = false

    var body: some View {
        NavigationStack(path: $path) {
            SearchView(model: session.search, indexing: session.indexing, userData: session.userData,
                       showsStatusLine: launchOptions.waitForIndex)
                .navigationDestination(for: Route.self) { route in
                    RouteDestination(route: route, session: session)
                }
        }
        .environment(\.openRoute, OpenRouteAction { route in path.append(route) })
        .environment(\.replaceRoute, ReplaceRouteAction { route in path.append(route) })
        .onAppear {
            guard !didLaunchSearch, let text = launchOptions.searchText else { return }
            didLaunchSearch = true
            session.search.submit(text)
        }
        .onChange(of: session.indexing.isComplete) { _, complete in
            guard complete else { return }
            Task { await session.search.indexingDidComplete() }
        }
    }
}

/// The Map tab. The first appear loads the pins for the initial region; a
/// launch `--map-place` then flies there and opens its sheet, once.
struct MapRoot: View {
    let session: AppSession
    let launchOptions: LaunchOptions
    @State private var didLaunchPlace = false

    var body: some View {
        MapScreen(model: session.map, session: session)
            .task {
                await session.map.start()
                guard !didLaunchPlace, let place = launchOptions.mapPlace else { return }
                didLaunchPlace = true
                await session.map.focus(on: place)
            }
    }
}
