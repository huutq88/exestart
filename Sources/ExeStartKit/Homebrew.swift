import Foundation

/// Cài công cụ phụ trợ (vd. cabextract) qua Homebrew — chỉ khi người dùng đồng ý.
public enum Homebrew {
    public static let website = "https://brew.sh"

    public static var executable: URL? { Shell.which("brew") }
    public static var isInstalled: Bool { executable != nil }

    /// `brew install <formulae>`, đẩy output ra `output`. Trả về mã thoát.
    public static func install(_ formulae: [String],
                               output: (@Sendable (String) -> Void)? = nil) async throws -> Int32 {
        guard let brew = executable else {
            throw BuildError.missingTools([("brew", "Cài Homebrew tại \(website)")])
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.searchPath
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        // Không hỏi gì trên terminal: app GUI không có stdin.
        env["NONINTERACTIVE"] = "1"
        output?("$ brew install \(formulae.joined(separator: " "))\n")
        return try await Shell.stream(brew, ["install"] + formulae, environment: env, output: output)
    }

    /// Cài các công cụ winetricks còn thiếu. Trả về true nếu sau đó không còn thiếu gì.
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
