import Foundation

/// Installs Windows libraries (vcrun, .NET, fonts...) into a bottle with winetricks.
public struct Winetricks: Sendable {
    public static let scriptURL = URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks")!

    /// Packages commonly needed by office apps and utilities.
    public static let common: [(verb: String, title: String)] = [
        ("corefonts", "Microsoft core fonts (Arial, Times...)"),
        ("tahoma", "Tahoma font"),
        ("cjkfonts", "Chinese/Japanese/Korean fonts"),
        ("vcrun2022", "Visual C++ 2015–2022 runtime"),
        ("vcrun2013", "Visual C++ 2013 runtime"),
        ("vcrun2010", "Visual C++ 2010 runtime"),
        ("dotnet48", ".NET Framework 4.8"),
        ("dotnetdesktop8", ".NET Desktop Runtime 8"),
        ("msxml6", "MSXML 6"),
        ("gdiplus", "Native Microsoft GDI+"),
        ("riched20", "Native RichEdit (fixes text input fields)"),
        ("mfc140", "MFC 14"),
    ]

    public let paths: Paths
    public init(paths: Paths = .shared) { self.paths = paths }

    public var scriptPath: URL { paths.cache.appendingPathComponent("winetricks") }

    /// External tools winetricks needs (cabextract unpacks Microsoft .cab files).
    /// Tool names match their Homebrew formula names.
    public static let requiredTools = ["cabextract"]

    public static var missingTools: [String] {
        // EXESTART_ASSUME_MISSING=cabextract: pretend the tool is missing to test the install flow.
        let forced = Set((ProcessInfo.processInfo.environment["EXESTART_ASSUME_MISSING"] ?? "")
            .split(separator: ",").map(String.init))
        return requiredTools.filter { forced.contains($0) || Shell.which($0) == nil }
    }

    public func ensureScript(forceUpdate: Bool = false) async throws -> URL {
        try paths.ensureExists()
        if forceUpdate || !FileManager.default.fileExists(atPath: scriptPath.path) {
            _ = try await Downloader.download(Self.scriptURL, to: scriptPath)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        }
        return scriptPath
    }

    /// Runs winetricks, streaming each output line to `output`. Returns the exit code.
    public func run(_ verbs: [String], wine: Wine,
                    output: (@Sendable (String) -> Void)? = nil) async throws -> Int32 {
        let script = try await ensureScript()
        var env = wine.environment
        env["WINE"] = wine.runtime.wineBinary.path
        env["WINESERVER"] = wine.runtime.wineserver.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--unattended"] + verbs
        process.environment = env
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
                cont.resume(returning: p.terminationStatus)
            }
            do { try process.run() } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
    }
}
