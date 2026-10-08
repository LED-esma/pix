import os

/// What Pix is doing, readable in Console.app (search "com.ramonledesma.pix").
/// Goals and answers are logged as private, so they show up only on your own Mac.
enum Log {
    private static let subsystem = "com.ramonledesma.pix"
    static let runner = Logger(subsystem: subsystem, category: "runner")
    static let crew = Logger(subsystem: subsystem, category: "crew")
    static let forge = Logger(subsystem: subsystem, category: "forge")
    static let tour = Logger(subsystem: subsystem, category: "tour")
    static let app = Logger(subsystem: subsystem, category: "app")
}
