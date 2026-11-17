import Foundation

/// Runs Wine in a specific bottle.
public struct Wine: Sendable {
    public let bottle: Bottle
    public let runtime: Runtime
    public var verbose = false

    public init(bottle: Bottle, runtime: Runtime) {
        self.bottle = bottle
        self.runtime = runtime
    }

    public var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.prefix.path
        env["WINEDEBUG"] = verbose ? "err+all,warn+module" : "-all"
        // By default MoltenVK (Vulkan → Metal) writes hundreds of lines of GPU info to the log.
        if !verbose, env["MVK_CONFIG_LOG_LEVEL"] == nil { env["MVK_CONFIG_LOG_LEVEL"] = "0" }
        env["PATH"] = runtime.binDirectory.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        // Render Vietnamese/Asian text correctly when the app doesn't set its own locale.
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (k, v) in bottle.config.environment { env[k] = v }
        return env
    }

    // MARK: Running programs

    /// How to invoke Wine for each file type.
    static func arguments(for file: URL, extra: [String]) -> [String] {
        switch file.pathExtension.lowercased() {
        case "msi": return ["msiexec", "/i", file.path] + extra
        case "bat", "cmd": return ["cmd", "/c", file.path] + extra
        case "lnk": return ["start", "/unix", file.path] + extra
        default: return [file.path] + extra
        }
    }

    /// Launches a program, logging to bottle/logs. Returns the running Process.
    @discardableResult
    public func launch(_ file: URL, arguments extra: [String] = [],
                       onExit: (@Sendable (Int32) -> Void)? = nil) throws -> (Process, URL) {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ExeStartError.fileNotFound(file.path)
        }
        try FileManager.default.createDirectory(at: bottle.logs, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let log = bottle.logs.appendingPathComponent("\(stamp)-\(file.deletingPathExtension().lastPathComponent).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)

        let process = Process()
        process.executableURL = runtime.wineBinary
        process.arguments = Self.arguments(for: file, extra: extra)
        process.environment = environment
        // Many Windows apps read files next to the .exe via relative paths.
        process.currentDirectoryURL = file.deletingLastPathComponent()
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { p in
            try? handle.close()
            onExit?(p.terminationStatus)
        }
        try process.run()
        return (process, log)
    }

    /// Runs a built-in Wine command (winecfg, regedit, ...) and waits for it to finish.
    @discardableResult
    public func run(_ arguments: [String]) throws -> String {
        try Shell.run(runtime.wineBinary.path, arguments, environment: environment)
    }

    /// Opens a Wine GUI tool without blocking the calling thread.
    public func openTool(_ tool: WineTool) throws {
        let process = Process()
        process.executableURL = runtime.wineBinary
        process.arguments = tool.arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // MARK: Prefix management

    public func boot() throws {
        try FileManager.default.createDirectory(at: bottle.prefix, withIntermediateDirectories: true)
        try run(["wineboot", "--init"])
        waitServer()
    }

    public func setWindowsVersion(_ version: WindowsVersion) throws {
        try run(["winecfg", "/v", version.rawValue])
        waitServer()
    }

    /// Retina: render at the Mac display's native resolution (sharper text, smaller windows).
    public func setRetinaMode(_ on: Bool) throws {
        try regAdd(key: #"HKCU\Software\Wine\Mac Driver"#, value: "RetinaMode", type: "REG_SZ", data: on ? "y" : "n")
    }

    public func setDPI(_ dpi: Int) throws {
        try regAdd(key: #"HKCU\Control Panel\Desktop"#, value: "LogPixels", type: "REG_DWORD", data: String(dpi))
    }

    public func regAdd(key: String, value: String, type: String, data: String) throws {
        try run(["reg", "add", key, "/v", value, "/t", type, "/d", data, "/f"])
        waitServer()
    }

    /// Kills all Wine processes of the bottle.
    public func kill() {
        _ = try? Shell.run(runtime.wineserver.path, ["-k"], environment: environment)
    }

    /// Waits for wineserver to flush the registry to disk.
    public func waitServer() {
        _ = try? Shell.run(runtime.wineserver.path, ["-w"], environment: environment)
    }

    /// While a prefix's wineserver is running, it has a socket at /tmp/.wine-<uid>/server-<dev>-<inode>/socket.
    public var isRunning: Bool {
        var st = stat()
        guard stat(bottle.prefix.path, &st) == 0 else { return false }
        let dir = String(format: "/tmp/.wine-%u/server-%llx-%llx",
                         getuid(), UInt64(UInt32(bitPattern: st.st_dev)), UInt64(st.st_ino))
        return FileManager.default.fileExists(atPath: dir + "/socket")
    }
}

public enum WineTool: String, CaseIterable, Sendable {
    case winecfg, regedit, taskmgr, control, uninstaller, explorer, cmd

    public var arguments: [String] {
        switch self {
        case .explorer: ["explorer", "C:\\"]
        case .cmd: ["start", "cmd"]
        default: [rawValue]
        }
    }

    public var displayName: String {
        switch self {
        case .winecfg: "Wine Configuration"
        case .regedit: "Registry"
        case .taskmgr: "Task Manager"
        case .control: "Control Panel"
        case .uninstaller: "Uninstall Programs"
        case .explorer: "Browse C: Drive"
        case .cmd: "Command Prompt"
        }
    }
}
