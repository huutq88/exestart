import Foundation

public enum ExeStartError: LocalizedError {
    case commandFailed(String, Int32, String)
    case noRuntime
    case runtimeNotFound(String)
    case bottleExists(String)
    case bottleNotFound(String)
    case invalidName(String)
    case fileNotFound(String)
    case rosettaMissing
    case download(String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(cmd, code, output):
            let tail = output.split(separator: "\n").suffix(15).joined(separator: "\n")
            return "Command \(cmd) exited with code \(code).\n\(tail)"
        case .noRuntime:
            return "No Wine runtime installed. Run: exestart runtime install"
        case let .runtimeNotFound(id):
            return "Runtime '\(id)' not found. To list runtimes, run: exestart runtime list"
        case let .bottleExists(name):
            return "Bottle '\(name)' already exists."
        case let .bottleNotFound(name):
            return "Bottle '\(name)' not found. To list bottles, run: exestart bottle list"
        case let .invalidName(name):
            return "Invalid name '\(name)'. Use only letters, digits, spaces, '-', '_' and '.'."
        case let .fileNotFound(path):
            return "File not found: \(path)"
        case .rosettaMissing:
            return "Wine requires Rosetta 2. Install it with: softwareupdate --install-rosetta --agree-to-license"
        case let .download(msg):
            return "Download failed: \(msg)"
        }
    }
}

enum Shell {
    /// Runs a command, waits for it, and returns stdout+stderr. Throws on a non-zero exit code.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String]? = nil,
                    currentDirectory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ExeStartError.commandFailed(
                ([executable] + arguments).joined(separator: " "), process.terminationStatus, output)
        }
        return output
    }

    /// Runs a command, streaming each output chunk to `output`, and returns the exit code (does not throw on non-zero).
    static func stream(_ executable: URL, _ arguments: [String],
                       environment: [String: String]? = nil,
                       currentDirectory: URL? = nil,
                       output: (@Sendable (String) -> Void)? = nil) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            output?(String(decoding: data, as: UTF8.self))
        }
        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                // Drain whatever is left in the pipe.
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { output?(String(decoding: rest, as: UTF8.self)) }
                cont.resume(returning: p.terminationStatus)
            }
            do { try process.run() } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
    }

    /// Directories that often hold dev tools but may be missing from a GUI app's PATH.
    static var extraPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin", "/usr/local/go/bin",
                "\(home)/go/bin", "/usr/local/share/dotnet", "\(home)/.dotnet"]
    }

    static var searchPath: String {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return (current.split(separator: ":").map(String.init) + extraPaths)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ":")
    }

    /// Finds an executable by name in PATH (plus extraPaths).
    static func which(_ tool: String) -> URL? {
        for dir in searchPath.split(separator: ":") {
            let path = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static var rosettaInstalled: Bool {
        // Intel Macs don't need Rosetta.
        #if arch(arm64)
        return FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
        #else
        return true
        #endif
    }
}

/// Bottle/runtime name: safe to use as a directory name.
func validateName(_ name: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
    guard !name.isEmpty, name.count <= 64, !name.hasPrefix("."),
          name.unicodeScalars.allSatisfy(allowed.contains) else {
        throw ExeStartError.invalidName(name)
    }
}
