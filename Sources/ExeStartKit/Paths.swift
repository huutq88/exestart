import Foundation

/// Where ExeStart stores everything. Default: ~/Library/Application Support/ExeStart.
/// Set the EXESTART_HOME environment variable to override it (useful for tests).
public struct Paths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let env = ProcessInfo.processInfo.environment["EXESTART_HOME"], !env.isEmpty {
            self.root = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("ExeStart", isDirectory: true)
        }
    }

    public static let shared = Paths()

    public var runtimes: URL { root.appendingPathComponent("Runtimes", isDirectory: true) }
    public var bottles: URL { root.appendingPathComponent("Bottles", isDirectory: true) }
    public var cache: URL { root.appendingPathComponent("Cache", isDirectory: true) }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }

    /// Shortcut .app bundles created for each program.
    public var shortcuts: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/ExeStart", isDirectory: true)
    }

    public func ensureExists() throws {
        for dir in [root, runtimes, bottles, cache] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
