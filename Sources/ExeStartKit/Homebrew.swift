import Foundation

/// Installs helper tools (e.g. cabextract) via Homebrew, only with the user's consent.
public enum Homebrew {
    public static let website = "https://brew.sh"

    public static var executable: URL? { Shell.which("brew") }
    public static var isInstalled: Bool { executable != nil }

    /// Runs `brew install <formulae>`, streaming output to `output`. Returns the exit code.
    public static func install(_ formulae: [String],
                               output: (@Sendable (String) -> Void)? = nil) async throws -> Int32 {
        guard let brew = executable else {
            throw BuildError.missingTools([("brew", "Install Homebrew from \(website)")])
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.searchPath
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        // Never prompt on the terminal: the GUI app has no stdin.
        env["NONINTERACTIVE"] = "1"
        output?("$ brew install \(formulae.joined(separator: " "))\n")
        return try await Shell.stream(brew, ["install"] + formulae, environment: env, output: output)
    }

    /// Installs missing winetricks tools. Returns true if nothing is missing afterwards.
    @discardableResult
    public static func installWinetricksTools(output: (@Sendable (String) -> Void)? = nil) async throws -> Bool {
        let missing = Winetricks.missingTools
        if !missing.isEmpty {
            let code = try await install(missing, output: output)
            guard code == 0 else { throw ExeStartError.commandFailed("brew install", code, "") }
        }
        return Winetricks.requiredTools.allSatisfy { Shell.which($0) != nil }
    }
}
