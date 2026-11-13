import SwiftUI
import UIKit

@main
struct RelateBooksApp: App {
    @State private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
                .task { await environment.start() }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    // D5: stop embedding, keep the model (search needs it);
                    // resumes by itself after 10 s.
                    indexing?.pauseForMemoryWarning()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // D4: the batch in flight commits whole or not at all; the
                // store holds the progress. Then fold the WAL (D11).
                indexing?.pause()
                Task { await environment.checkpoint() }
            case .active:
                indexing?.resume()
            default:
                break
            }
        }
    }

    private var indexing: IndexingModel? {
        if case .ready(let session) = environment.state { return session.indexing }
        return nil
    }
}
