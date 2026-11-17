import Foundation

/// Python không biên dịch chéo được, nên ExeStart chạy Python *bản Windows* + PyInstaller bên trong Wine.
/// Lần đầu: tạo bottle "Python Build", tải trình cài Python từ python.org và cài PyInstaller.
public struct PythonBuilder: Sendable {
    public static let pythonVersion = "3.12.10"
    public static let installerURL = URL(string: "https://www.python.org/ftp/python/\(pythonVersion)/python-\(pythonVersion)-amd64.exe")!
    public static let bottleName = "Python Build"
    static let windowsDir = #"C:\Python312"#

    public let bottles: BottleManager
    public init(bottles: BottleManager = BottleManager()) { self.bottles = bottles }

    // MARK: Entry point

    /// Tìm file .py chính: file được chỉ định, hoặc main.py / app.py / __main__.py / <tên thư mục>.py.
    public static func entryPoint(for project: URL) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDir) else {
            throw ExeStartError.fileNotFound(project.path)
        }
        if !isDir.boolValue { return project }
        let candidates = ["main.py", "app.py", "__main__.py", "\(project.lastPathComponent).py"]
        for name in candidates {
            let url = project.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let pys = ((try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? [])
            .filter { $0.hasSuffix(".py") && !$0.hasPrefix("test") && $0 != "setup.py" }
        if pys.count == 1 { return project.appendingPathComponent(pys[0]) }
        throw BuildError.noEntryPoint(
            "Không biết file Python nào là file chính trong \(project.path). Hãy chỉ thẳng file, vd. exestart build \(project.path)/main.py")
    }

    /// Đường dẫn Unix → Windows qua ổ Z: (Wine map Z: = thư mục gốc /).
    static func windowsPath(_ url: URL) -> String {
        "Z:" + url.standardizedFileURL.path.replacingOccurrences(of: "/", with: #"\"#)
    }

    // MARK: Build

    public func build(_ project: URL, options: BuildOptions,
                      output: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        if options.arch != .x64 {
            throw BuildError.noEntryPoint("Build Python hiện chỉ hỗ trợ x64.")
        }
        let script = try Self.entryPoint(for: project.standardizedFileURL)
        let dir = script.deletingLastPathComponent()
        let name = options.name ?? script.deletingPathExtension().lastPathComponent
        let outDir = options.output.map { $0.pathExtension.lowercased() == "exe" ? $0.deletingLastPathComponent() : $0 }
            ?? dir.appendingPathComponent("build/windows", isDirectory: true)
        let workDir = dir.appendingPathComponent("build/pyinstaller", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let wine = try await prepare(output: output)
        let python = wine.bottle.driveC.appendingPathComponent("Python312/python.exe")

        let requirements = dir.appendingPathComponent("requirements.txt")
        if FileManager.default.fileExists(atPath: requirements.path) {
            output?("▸ Cài thư viện từ requirements.txt\n")
            try await runPython(wine, python, ["-m", "pip", "install", "--disable-pip-version-check",
                                               "-r", Self.windowsPath(requirements)], in: dir, output: output)
        }

        var args = ["-m", "PyInstaller", "--onefile", "--noconfirm", "--clean",
                    "--name", name,
                    "--distpath", Self.windowsPath(outDir),
                    "--workpath", Self.windowsPath(workDir),
                    "--specpath", Self.windowsPath(workDir)]
        if options.gui { args.append("--noconsole") }
        args.append(Self.windowsPath(script))
        output?("▸ PyInstaller → \(name).exe\n")
        try await runPython(wine, python, args, in: dir, output: output)

        let exe = outDir.appendingPathComponent("\(name).exe")
        guard FileManager.default.fileExists(atPath: exe.path) else { throw BuildError.noOutput(outDir.path) }
        return exe
    }

    /// Dựng bottle có Python + PyInstaller nếu chưa có. Trả về Wine của bottle đó.
    public func prepare(output: (@Sendable (String) -> Void)? = nil) async throws -> Wine {
        let bottle: Bottle
        if let existing = try? bottles.bottle(named: Self.bottleName) {
            bottle = existing
        } else {
            output?("▸ Tạo bottle “\(Self.bottleName)” (một lần, ~30 giây)\n")
            let mgr = bottles
            bottle = try await Task.detached { try mgr.create(name: Self.bottleName) }.value
        }
        let wine = try bottles.wine(for: bottle)
        let python = bottle.driveC.appendingPathComponent("Python312/python.exe")

        if !FileManager.default.fileExists(atPath: python.path) {
            let installer = bottles.paths.cache.appendingPathComponent(Self.installerURL.lastPathComponent)
            if !FileManager.default.fileExists(atPath: installer.path) {
                output?("▸ Tải Python \(Self.pythonVersion) cho Windows từ python.org\n")
                _ = try await Downloader.download(Self.installerURL, to: installer)
            }
            output?("▸ Cài Python \(Self.pythonVersion) vào bottle (1–3 phút)\n")
            let code = try await Shell.stream(
                wine.runtime.wineBinary,
                [installer.path, "/quiet", "InstallAllUsers=0", "PrependPath=0", "Include_test=0",
                 "Include_launcher=0", "Include_doc=0", "Shortcuts=0", "AssociateFiles=0",
                 "TargetDir=\(Self.windowsDir)"],
                environment: wine.environment, output: nil)
            wine.waitServer()
            guard code == 0, FileManager.default.fileExists(atPath: python.path) else {
                throw BuildError.stepFailed("Cài Python cho Windows", code)
            }
        }

        let pyinstaller = bottle.driveC.appendingPathComponent("Python312/Scripts/pyinstaller.exe")
        if !FileManager.default.fileExists(atPath: pyinstaller.path) {
            output?("▸ Cài PyInstaller\n")
            try await runPython(wine, python, ["-m", "pip", "install", "--disable-pip-version-check", "pyinstaller"],
                                in: nil, output: output)
        }
        return wine
    }

    private func runPython(_ wine: Wine, _ python: URL, _ args: [String], in dir: URL?,
                           output: (@Sendable (String) -> Void)?) async throws {
        var env = wine.environment
        env["PYTHONUTF8"] = "1"
        let code = try await Shell.stream(wine.runtime.wineBinary, [python.path] + args,
                                          environment: env, currentDirectory: dir, output: output)
        guard code == 0 else { throw BuildError.stepFailed("python " + args.prefix(3).joined(separator: " "), code) }
    }
}
