import OSLog

/// Unified-logging channels. Subsystem = bundle id so `log stream --predicate
/// 'subsystem == "com.johnymontana.RelateBooks"'` finds them.
enum Log {
    static let subsystem = "com.johnymontana.RelateBooks"
    static let store = Logger(subsystem: subsystem, category: "store")
    static let query = Logger(subsystem: subsystem, category: "query")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
