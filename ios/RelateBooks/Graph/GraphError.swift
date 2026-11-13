import Foundation

enum GraphError: Error, Equatable, LocalizedError {
    /// A required result column was absent, null, or of the wrong kind.
    case missingColumn(String)
    /// The app bundle does not contain books.rl.
    case bundledStoreMissing

    var errorDescription: String? {
        switch self {
        case .missingColumn(let c): "Query result is missing column '\(c)'"
        case .bundledStoreMissing: "The bundled books.rl store is missing from the app"
        }
    }
}
