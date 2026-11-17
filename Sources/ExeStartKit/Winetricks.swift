import Foundation

/// Cài thư viện Windows (vcrun, .NET, font...) vào bottle bằng winetricks.
public struct Winetricks: Sendable {
    public static let scriptURL = URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks")!

    /// Các gói hay dùng cho app văn phòng/công cụ.
    public static let common: [(verb: String, title: String)] = [
        ("corefonts", "Font Microsoft cơ bản (Arial, Times...)"),
        ("tahoma", "Font Tahoma"),
        ("cjkfonts", "Font Trung/Nhật/Hàn"),
        ("vcrun2022", "Visual C++ 2015–2022 runtime"),
        ("vcrun2013", "Visual C++ 2013 runtime"),
        ("vcrun2010", "Visual C++ 2010 runtime"),
        ("dotnet48", ".NET Framework 4.8"),
        ("dotnetdesktop8", ".NET Desktop Runtime 8"),
        ("msxml6", "MSXML 6"),
        ("gdiplus", "GDI+ gốc của Microsoft"),
        ("riched20", "RichEdit gốc (sửa lỗi ô nhập văn bản)"),
        ("mfc140", "MFC 14"),
    ]

    public let paths: Paths
    public init(paths: Paths = .shared) { self.paths = paths }

    public var scriptPath: URL { paths.cache.appendingPathComponent("winetricks") }

    /// Công cụ ngoài mà winetricks cần (cabextract giải nén file .cab của Microsoft).
    /// Tên công cụ trùng tên formula Homebrew.
    public static let requiredTools = ["cabextract"]

    public static var missingTools: [String] {
        // EXESTART_ASSUME_MISSING=cabextract: giả lập thiếu công cụ để thử luồng cài đặt.
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

    /// Chạy winetricks, đẩy từng dòng output ra `output`. Trả về mã thoát.
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
