import Foundation

/// Finds the bundled model folder (`Model/MiniLM_L6_v2.mlmodelc`,
/// `Model/vocab.txt`).
///
/// - SwiftPM (`swift test`): `resources: [.copy("Embedding/Model")]` puts
///   the folder in `Bundle.module`.
/// - The app: project.yml adds `RelateBooks/Embedding/Model` as a folder
///   reference, so the same layout sits in `Bundle.main`.
///
/// The model is pre-compiled (`.mlmodelc`) because SwiftPM does not compile
/// Core ML models.
enum EmbeddingResources {
    static let subdirectory = "Model"
    static let modelName = "MiniLM_L6_v2"

    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func modelURL(in bundle: Bundle = bundle) -> URL? {
        bundle.url(forResource: modelName, withExtension: "mlmodelc", subdirectory: subdirectory)
    }

    static func vocabURL(in bundle: Bundle = bundle) -> URL? {
        bundle.url(forResource: "vocab", withExtension: "txt", subdirectory: subdirectory)
    }
}
