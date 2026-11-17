import Foundation

/// The Windows version Wine emulates (value passed to `winecfg /v`).
public enum WindowsVersion: String, Codable, CaseIterable, Sendable {
    case win11, win10, win81, win8, win7, winxp

    public var displayName: String {
        switch self {
        case .win11: "Windows 11"
        case .win10: "Windows 10"
        case .win81: "Windows 8.1"
        case .win8: "Windows 8"
        case .win7: "Windows 7"
        case .winxp: "Windows XP"
        }
    }
}

public struct BottleConfig: Codable, Sendable, Equatable {
    public var runtimeID: String?
    public var windowsVersion: WindowsVersion = .win10
    public var retinaMode: Bool = false
    public var dpi: Int = 96
    public var environment: [String: String] = [:]
    /// Unix paths of the .exe files the user pinned.
    public var pinned: [String] = []
    public var createdAt: Date = Date()

    public init(runtimeID: String? = nil, windowsVersion: WindowsVersion = .win10) {
        self.runtimeID = runtimeID
        self.windowsVersion = windowsVersion
    }

    // Tolerate older files with missing keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runtimeID = try c.decodeIfPresent(String.self, forKey: .runtimeID)
        windowsVersion = try c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion) ?? .win10
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? false
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi) ?? 96
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// A "bottle" is a separate Wine prefix with its own C: drive, registry and settings.
public struct Bottle: Identifiable, Hashable, Sendable {
    public let name: String
    public let directory: URL
    public var config: BottleConfig

    public var id: String { name }
    public var prefix: URL { directory.appendingPathComponent("prefix", isDirectory: true) }
    public var driveC: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }
    public var logs: URL { directory.appendingPathComponent("logs", isDirectory: true) }
    var configFile: URL { directory.appendingPathComponent("bottle.json") }

    public static func == (a: Bottle, b: Bottle) -> Bool { a.name == b.name && a.config == b.config }
    public func hash(into h: inout Hasher) { h.combine(name) }

    public func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: configFile)
    }
}

/// A program found in a bottle.
public struct Program: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case pinned, startMenu, executable }
    public let name: String
    public let url: URL
    public let kind: Kind
    public var id: String { url.path }
}

public final class BottleManager: @unchecked Sendable {
    public let paths: Paths
    public let runtimes: RuntimeManager

    public init(paths: Paths = .shared) {
        self.paths = paths
        self.runtimes = RuntimeManager(paths: paths)
    }

    public func list() -> [Bottle] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: paths.bottles, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap(load).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func bottle(named name: String) throws -> Bottle {
        guard let b = load(paths.bottles.appendingPathComponent(name, isDirectory: true)) else {
            throw ExeStartError.bottleNotFound(name)
        }
        return b
    }

    private func load(_ dir: URL) -> Bottle? {
        let file = dir.appendingPathComponent("bottle.json")
        guard let data = try? Data(contentsOf: file),
              let config = try? JSONDecoder().decode(BottleConfig.self, from: data) else { return nil }
        return Bottle(name: dir.lastPathComponent, directory: dir, config: config)
    }

    /// Creates a new bottle and runs `wineboot --init` to set up the C: drive and registry.
    @discardableResult
    public func create(name: String, runtimeID: String? = nil,
                       windowsVersion: WindowsVersion = .win10) throws -> Bottle {
        try validateName(name)
        try paths.ensureExists()
        let dir = paths.bottles.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw ExeStartError.bottleExists(name) }
        let runtime = try runtimes.runtime(id: runtimeID)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var bottle = Bottle(name: name, directory: dir,
                            config: BottleConfig(runtimeID: runtimeID, windowsVersion: windowsVersion))
        do {
            try bottle.save()
            let wine = Wine(bottle: bottle, runtime: runtime)
            try wine.boot()
            try wine.setWindowsVersion(windowsVersion)
            bottle.config.windowsVersion = windowsVersion
            try bottle.save()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return bottle
    }

    public func delete(_ bottle: Bottle) throws {
        if let wine = try? wine(for: bottle) { wine.kill() }
        try FileManager.default.trashItem(at: bottle.directory, resultingItemURL: nil)
    }

    public func wine(for bottle: Bottle) throws -> Wine {
        Wine(bottle: bottle, runtime: try runtimes.runtime(id: bottle.config.runtimeID))
    }

    // MARK: Programs

    public func programs(in bottle: Bottle) -> [Program] {
        var seen = Set<String>()
        var result: [Program] = []
        func add(_ p: Program) {
            guard seen.insert(p.name.lowercased()).inserted else { return }
            result.append(p)
        }
        for path in bottle.config.pinned {
            let url = URL(fileURLWithPath: path)
            add(Program(name: url.deletingPathExtension().lastPathComponent, url: url, kind: .pinned))
        }
        startMenuShortcuts(in: bottle).forEach(add)
        installedExecutables(in: bottle).forEach(add)
        return result
    }

    private func startMenuShortcuts(in bottle: Bottle) -> [Program] {
        let c = bottle.driveC
        var roots = [c.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs")]
        if let users = try? FileManager.default.contentsOfDirectory(
            at: c.appendingPathComponent("users"), includingPropertiesForKeys: nil) {
            roots += users.map { $0.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu/Programs") }
        }
        return roots.flatMap { files(in: $0, ext: "lnk", maxDepth: 3) }
            .filter { !Self.isNoise($0.deletingPathExtension().lastPathComponent) }
            .map { Program(name: $0.deletingPathExtension().lastPathComponent, url: $0, kind: .startMenu) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func installedExecutables(in bottle: Bottle) -> [Program] {
        // Skip programs that Wine installs by default.
        let builtin: Set<String> = ["Common Files", "Internet Explorer", "Windows Media Player",
                                    "Windows NT", "Microsoft.NET", "Windows Mail", "Windows Defender"]
        var result: [Program] = []
        for folder in ["Program Files", "Program Files (x86)"] {
            let root = bottle.driveC.appendingPathComponent(folder)
            guard let vendors = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { continue }
            for vendor in vendors where !builtin.contains(vendor.lastPathComponent) {
                for exe in files(in: vendor, ext: "exe", maxDepth: 2)
                where !Self.isNoise(exe.deletingPathExtension().lastPathComponent) {
                    result.append(Program(name: exe.deletingPathExtension().lastPathComponent,
                                          url: exe, kind: .executable))
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isNoise(_ name: String) -> Bool {
        let n = name.lowercased()
        // "gỡ" is Vietnamese for "uninstall" and matches localized uninstaller names.
        let words = ["unins", "uninstall", "gỡ", "setup", "update", "crashreport", "crashpad",
                     "helper", "elevat", "vcredist", "dxsetup", "readme", "help", "license"]
        return words.contains { n.contains($0) }
    }

    private func files(in root: URL, ext: String, maxDepth: Int) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        let base = root.pathComponents.count
        for case let url as URL in walker {
            if url.pathComponents.count - base > maxDepth { walker.skipDescendants(); continue }
            if url.pathExtension.lowercased() == ext { out.append(url) }
        }
        return out
    }

    public func pin(_ file: URL, in bottle: inout Bottle) throws {
        guard !bottle.config.pinned.contains(file.path) else { return }
        bottle.config.pinned.append(file.path)
        try bottle.save()
    }

    public func unpin(_ file: URL, in bottle: inout Bottle) throws {
        bottle.config.pinned.removeAll { $0 == file.path }
        try bottle.save()
    }
}
