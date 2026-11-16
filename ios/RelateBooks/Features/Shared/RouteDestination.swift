import SwiftUI

/// Maps a `Route` to its screen. Every model gets the shared
/// `UserDataController`, so a write on one screen updates the others.
struct RouteDestination: View {
    let route: Route
    let session: AppSession

    var body: some View {
        switch route {
        case .book(let key):
            BookDetailView(model: session.bookDetailModel(key: key), indexing: session.indexing)
        case .author(let key):
            AuthorView(model: AuthorModel(key: key, store: session.store, userData: session.userData))
        case .term(let kind, let name):
            TermBooksView(model: TermModel(kind: kind, name: name, store: session.store, userData: session.userData))
        case .tag(let name):
            TagBooksView(model: TagBooksModel(name: name, store: session.store, controller: session.userData))
        case .addBook:
            AddBookView(model: session.addBookModel())
        case .nextUp:
            NextUpView(model: session.nextUp)
        case .addedBook(let key, let notice):
            BookDetailView(model: session.bookDetailModel(key: key), indexing: session.indexing, notice: notice)
        }
    }
}
