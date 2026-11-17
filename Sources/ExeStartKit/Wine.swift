import Foundation

/// Chạy Wine trong một bottle cụ thể.
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
        // MoltenVK (Vulkan → Metal) mặc định in hàng trăm dòng thông tin GPU vào log.
        if !verbose, env["MVK_CONFIG_LOG_LEVEL"] == nil { env["MVK_CONFIG_LOG_LEVEL"] = "0" }
        env["PATH"] = runtime.binDirectory.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        // Font chữ Việt/Á hiển thị đúng khi app không tự set locale.
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (k, v) in bottle.config.environment { env[k] = v }
        return env
    }

    // MARK: Chạy chương trình

    /// Cách gọi Wine cho từng loại file.
    static func arguments(for file: URL, extra: [String]) -> [String] {
        switch file.pathExtension.lowercased() {
        case "msi": return ["msiexec", "/i", file.path] + extra
        case "bat", "cmd": return ["cmd", "/c", file.path] + extra
        case "lnk": return ["start", "/unix", file.path] + extra
        default: return [file.path] + extra
        }
    }

    /// Khởi động chương trình, ghi log ra bottle/logs. Trả về Process đang chạy.
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
        // Nhiều app Windows đọc file cạnh .exe theo đường dẫn tương đối.
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

    /// Chạy một lệnh Wine dựng sẵn (winecfg, regedit, ...) và chờ xong.
    @discardableResult
    public func run(_ arguments: [String]) throws -> String {
        try Shell.run(runtime.wineBinary.path, arguments, environment: environment)
    }

    /// Mở công cụ Wine có giao diện mà không chặn luồng gọi.
    public func openTool(_ tool: WineTool) throws {
        let process = Process()
        process.executableURL = runtime.wineBinary
        process.arguments = tool.arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // MARK: Quản lý prefix

    public func boot() throws {
        try FileManager.default.createDirectory(at: bottle.prefix, withIntermediateDirectories: true)
        try run(["wineboot", "--init"])
        waitServer()
    }

    public func setWindowsVersion(_ version: WindowsVersion) throws {
        try run(["winecfg", "/v", version.rawValue])
        waitServer()
    }

    /// Retina: vẽ ở độ phân giải gốc của màn hình Mac (chữ nét hơn, cửa sổ nhỏ hơn).
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

    /// Tắt mọi tiến trình Wine của bottle.
    public func kill() {
        _ = try? Shell.run(runtime.wineserver.path, ["-k"], environment: environment)
    }

    /// Chờ wineserver ghi registry xuống đĩa.
    public func waitServer() {
        _ = try? Shell.run(runtime.wineserver.path, ["-w"], environment: environment)
    }

    /// wineserver của prefix đang chạy thì có socket tại /tmp/.wine-<uid>/server-<dev>-<inode>/socket.
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
        case .winecfg: "Cấu hình Wine"
        case .regedit: "Registry"
        case .taskmgr: "Task Manager"
        case .control: "Control Panel"
        case .uninstaller: "Gỡ chương trình"
        case .explorer: "Duyệt ổ C:"
        case .cmd: "Command Prompt"
        }
    }
}
