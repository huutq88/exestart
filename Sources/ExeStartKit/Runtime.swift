import Foundation

/// Một bản Wine đã cài trong ExeStart/Runtimes/<id>.
public struct Runtime: Codable, Hashable, Identifiable, Sendable {
    public let id: String          // vd. "wine-stable-11.0_1"
    public let channel: String     // stable | devel | staging
    public let version: String     // vd. "11.0_1"
    public let directory: URL
    public let wineBinary: URL

    public var binDirectory: URL { wineBinary.deletingLastPathComponent() }
    public var wineserver: URL { binDirectory.appendingPathComponent("wineserver") }
    public var displayName: String { "Wine \(channel.capitalized) \(version)" }
}

/// Một bản Wine có thể tải về.
public struct RemoteRuntime: Hashable, Identifiable, Sendable {
    public let id: String
    public let channel: String
    public let version: String
    public let url: URL
    public let size: Int64
    public let publishedAt: Date?

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

public struct Settings: Codable, Sendable {
    public var defaultRuntime: String?
    public init(defaultRuntime: String? = nil) { self.defaultRuntime = defaultRuntime }
}

public final class RuntimeManager: @unchecked Sendable {
    public static let releasesAPI = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases?per_page=30")!

    public let paths: Paths
    public init(paths: Paths = .shared) { self.paths = paths }

    // MARK: Cài đặt cục bộ

    public func installed() -> [Runtime] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: paths.runtimes, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            let meta = dir.appendingPathComponent("runtime.json")
            guard let data = try? Data(contentsOf: meta),
                  let rt = try? JSONDecoder().decode(Runtime.self, from: data),
                  fm.isExecutableFile(atPath: rt.wineBinary.path) else { return nil }
            return rt
        }.sorted { $0.id < $1.id }
    }

    public func runtime(id: String?) throws -> Runtime {
        let all = installed()
        if let id {
            guard let rt = all.first(where: { $0.id == id }) else { throw ExeStartError.runtimeNotFound(id) }
            return rt
        }
        if let def = settings().defaultRuntime, let rt = all.first(where: { $0.id == def }) { return rt }
        guard let first = all.first(where: { $0.channel == "stable" }) ?? all.first else { throw ExeStartError.noRuntime }
        return first
    }

    public func settings() -> Settings {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func setDefault(_ id: String) throws {
        _ = try runtime(id: id)
        try paths.ensureExists()
        var s = settings()
        s.defaultRuntime = id
        try JSONEncoder().encode(s).write(to: paths.settingsFile)
    }

    public func remove(id: String) throws {
        let rt = try runtime(id: id)
        try FileManager.default.removeItem(at: rt.directory)
    }

    // MARK: Bản có thể tải

    public func available() async throws -> [RemoteRuntime] {
        var request = URLRequest(url: Self.releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ExeStart", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ExeStartError.download("GitHub API trả về HTTP \(http.statusCode)")
        }
        return try Self.parseReleases(data)
    }

    /// Đọc JSON releases của GitHub, lấy các asset `wine-<channel>-<version>-osx64.tar.xz`.
    static func parseReleases(_ data: Data) throws -> [RemoteRuntime] {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let size: Int64; let browser_download_url: URL }
            let published_at: String?
            let assets: [Asset]
        }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        let iso = ISO8601DateFormatter()
        var result: [RemoteRuntime] = []
        for release in releases {
            for asset in release.assets {
                guard let parsed = parseAssetName(asset.name) else { continue }
                result.append(RemoteRuntime(
                    id: "wine-\(parsed.channel)-\(parsed.version)", channel: parsed.channel,
                    version: parsed.version, url: asset.browser_download_url, size: asset.size,
                    publishedAt: release.published_at.flatMap(iso.date(from:))))
            }
        }
        return result
    }

    static func parseAssetName(_ name: String) -> (channel: String, version: String)? {
        let suffix = "-osx64.tar.xz"
        guard name.hasPrefix("wine-"), name.hasSuffix(suffix) else { return nil }
        let core = name.dropFirst("wine-".count).dropLast(suffix.count)   // "stable-11.0_1"
        guard let dash = core.firstIndex(of: "-") else { return nil }
        let channel = String(core[..<dash])
        let version = String(core[core.index(after: dash)...])
        guard ["stable", "devel", "staging"].contains(channel), !version.isEmpty else { return nil }
        return (channel, version)
    }

    /// Tải và cài một runtime. `channel` mặc định là stable, lấy bản mới nhất.
    @discardableResult
    public func install(_ remote: RemoteRuntime,
                        progress: (@Sendable (String, Double?) -> Void)? = nil) async throws -> Runtime {
        guard Shell.rosettaInstalled else { throw ExeStartError.rosettaMissing }
        try paths.ensureExists()
        let archive = paths.cache.appendingPathComponent(remote.url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: archive.path) {
            progress?("Đang tải \(remote.id) (\(remote.sizeText))", 0)
            let partial = archive.appendingPathExtension("part")
            _ = try await Downloader.download(remote.url, to: partial) { p in progress?("Đang tải", p) }
            try FileManager.default.moveItem(at: partial, to: archive)
        }
        progress?("Đang giải nén", nil)
        let rt = try installArchive(archive, id: remote.id, channel: remote.channel, version: remote.version)
        try? FileManager.default.removeItem(at: archive)
        if settings().defaultRuntime == nil || installed().count == 1 { try setDefault(rt.id) }
        progress?("Đã cài \(rt.displayName)", 1)
        return rt
    }

    /// Giải nén file .tar.xz vào Runtimes/<id> và ghi runtime.json.
    func installArchive(_ archive: URL, id: String, channel: String, version: String) throws -> Runtime {
        let fm = FileManager.default
        let target = paths.runtimes.appendingPathComponent(id, isDirectory: true)
        let staging = paths.runtimes.appendingPathComponent(".\(id).tmp", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Shell.run("/usr/bin/tar", ["-xJf", archive.path, "-C", staging.path])
        // Bỏ cờ quarantine để Gatekeeper không chặn các dylib bên trong.
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])

        guard let wine = Self.findWineBinary(in: staging) else {
            throw ExeStartError.download("Không thấy file wine trong gói \(archive.lastPathComponent)")
        }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: staging, to: target)
        let relative = wine.path.replacingOccurrences(of: staging.path, with: target.path)
        let rt = Runtime(id: id, channel: channel, version: version, directory: target,
                         wineBinary: URL(fileURLWithPath: relative))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rt).write(to: target.appendingPathComponent("runtime.json"))
        return rt
    }

    /// Gói Gcenx có dạng "Wine Stable.app/Contents/Resources/wine/bin/wine".
    /// Wine ≥ 10 chỉ còn `wine` (WoW64); bản cũ có `wine64`.
    static func findWineBinary(in root: URL) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        var fallback: URL?
        for case let url as URL in walker where url.deletingLastPathComponent().lastPathComponent == "bin" {
            switch url.lastPathComponent {
            case "wine": if fm.isExecutableFile(atPath: url.path) { return url }
            case "wine64": if fm.isExecutableFile(atPath: url.path) { fallback = url }
            default: break
            }
        }
        return fallback
    }
}
