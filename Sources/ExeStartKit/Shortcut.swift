import Foundation

/// Tạo file .app trong ~/Applications/ExeStart để mở chương trình Windows từ Launchpad/Spotlight/Dock.
public enum Shortcut {
    @discardableResult
    public static func create(name: String, program: URL, wine: Wine, paths: Paths = .shared) throws -> URL {
        try validateName(name)
        let app = paths.shortcuts.appendingPathComponent("\(name).app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: app)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        let args = Wine.arguments(for: program, extra: []).map(shellQuote).joined(separator: " ")
        let script = """
        #!/bin/sh
        # Tạo bởi ExeStart — bottle: \(wine.bottle.name)
        export WINEPREFIX=\(shellQuote(wine.bottle.prefix.path))
        export WINEDEBUG=-all
        \(wine.bottle.config.environment.sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellQuote($0.value))" }.joined(separator: "\n"))
        cd \(shellQuote(program.deletingLastPathComponent().path))
        exec \(shellQuote(wine.runtime.wineBinary.path)) \(args)
        """
        let exe = macOS.appendingPathComponent("launcher")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let bundleID = "app.exestart.shortcut." + name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let plist: [String: Any] = [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "launcher",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "14.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
