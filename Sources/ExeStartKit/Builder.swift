import Foundation

/// Build dự án thành file .exe Windows ngay trên macOS bằng trình biên dịch chéo.
public enum ProjectKind: String, CaseIterable, Sendable {
    case go, rust, cmake, c, cpp, dotnet, python

    public var displayName: String {
        switch self {
        case .go: "Go"
        case .rust: "Rust"
        case .cmake: "C/C++ (CMake)"
        case .c: "C"
        case .cpp: "C++"
        case .dotnet: ".NET"
        case .python: "Python (PyInstaller qua Wine)"
        }
    }
}

public enum Arch: String, CaseIterable, Sendable {
    case x64, x86

    var goArch: String { self == .x64 ? "amd64" : "386" }
    var mingwPrefix: String { self == .x64 ? "x86_64-w64-mingw32" : "i686-w64-mingw32" }
    var rustGNU: String { self == .x64 ? "x86_64-pc-windows-gnu" : "i686-pc-windows-gnu" }
    var rustMSVC: String { self == .x64 ? "x86_64-pc-windows-msvc" : "i686-pc-windows-msvc" }
    var dotnetRID: String { self == .x64 ? "win-x64" : "win-x86" }
}

public struct BuildOptions: Sendable {
    public var kind: ProjectKind?
    public var arch: Arch = .x64
    /// Ứng dụng có cửa sổ: không bật cửa sổ console đen khi chạy.
    public var gui = false
    public var output: URL?
    public var name: String?

    public init(kind: ProjectKind? = nil, arch: Arch = .x64, gui: Bool = false,
                output: URL? = nil, name: String? = nil) {
        self.kind = kind; self.arch = arch; self.gui = gui; self.output = output; self.name = name
    }
}

/// Một bước của quá trình build (một lệnh chạy native trên Mac).
public struct BuildStep: Sendable, Equatable {
    public let title: String
    public let tool: String
    public let arguments: [String]
    public var environment: [String: String] = [:]
    public var directory: URL

    /// Lệnh dạng in ra được cho người dùng xem/copy.
    public var commandLine: String {
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return (env + [tool] + arguments.map(Shortcut.shellQuote)).joined(separator: " ")
    }
}

public struct BuildPlan: Sendable {
    public let kind: ProjectKind
    public let project: URL
    public let steps: [BuildStep]
    /// File .exe dự kiến. Với CMake/Rust thì tìm lại sau khi build.
    public let output: URL
    /// Công cụ cần có trên máy, kèm câu lệnh cài nếu thiếu.
    public let requirements: [(tool: String, install: String)]
    /// Nếu có: copy .exe tìm được về đây để mọi ngôn ngữ ra cùng một chỗ (build/windows).
    public var collectTo: URL? = nil
}

public enum BuildError: LocalizedError {
    case unknownProject(String)
    case missingTools([(tool: String, install: String)])
    case missingRustTarget(String)
    case noEntryPoint(String)
    case stepFailed(String, Int32)
    case noOutput(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownProject(path):
            return "Không nhận ra loại dự án ở \(path). Chỉ định bằng --lang (\(ProjectKind.allCases.map(\.rawValue).joined(separator: ", ")))."
        case let .missingTools(list):
            return "Thiếu công cụ để build:\n" + list.map { "  • \($0.tool) → \($0.install)" }.joined(separator: "\n")
        case let .missingRustTarget(target):
            return "Rust chưa có target \(target). Cài bằng: rustup target add \(target)"
        case let .noEntryPoint(msg):
            return msg
        case let .stepFailed(title, code):
            return "Bước “\(title)” thất bại (mã \(code)). Xem output ở trên."
        case let .noOutput(dir):
            return "Build xong nhưng không tìm thấy file .exe trong \(dir)."
        }
    }
}

public struct Builder: Sendable {
    public let paths: Paths
    public init(paths: Paths = .shared) { self.paths = paths }

    // MARK: Nhận diện dự án

    public static func detect(_ url: URL) -> ProjectKind? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            switch url.pathExtension.lowercased() {
            case "go": return .go
            case "rs": return .rust
            case "c": return .c
            case "cpp", "cc", "cxx": return .cpp
            case "csproj", "fsproj", "sln": return .dotnet
            case "py", "pyw": return .python
            default: return nil
            }
        }
        let names = Set((try? fm.contentsOfDirectory(atPath: url.path)) ?? [])
        if names.contains("go.mod") { return .go }
        if names.contains("Cargo.toml") { return .rust }
        if names.contains("CMakeLists.txt") { return .cmake }
        if names.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") || $0.hasSuffix(".sln") }) { return .dotnet }
        if names.contains("pyproject.toml") || names.contains("requirements.txt")
            || names.contains(where: { $0.hasSuffix(".py") }) { return .python }
        let sources = cSources(in: url)
        if sources.contains(where: { ["cpp", "cc", "cxx"].contains($0.pathExtension.lowercased()) }) { return .cpp }
        if !sources.isEmpty { return .c }
        if names.contains(where: { $0.hasSuffix(".go") }) { return .go }
        return nil
    }

    static func cSources(in dir: URL) -> [URL] {
        let exts: Set<String> = ["c", "cpp", "cc", "cxx"]
        var roots = [dir]
        let src = dir.appendingPathComponent("src")
        if FileManager.default.fileExists(atPath: src.path) { roots.append(src) }
        return roots.flatMap { root in
            ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { exts.contains($0.pathExtension.lowercased()) }
        }.sorted { $0.path < $1.path }
    }

    // MARK: Lập kế hoạch build

    /// Tạo kế hoạch build cho các ngôn ngữ biên dịch chéo native (không gồm Python).
    public func plan(_ project: URL, options: BuildOptions = BuildOptions()) throws -> BuildPlan {
        let project = project.standardizedFileURL
        guard let kind = options.kind ?? Self.detect(project) else {
            throw BuildError.unknownProject(project.path)
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: project.path, isDirectory: &isDir)
        let dir = isDir.boolValue ? project : project.deletingLastPathComponent()
        let baseName = options.name
            ?? (isDir.boolValue ? project.lastPathComponent : project.deletingPathExtension().lastPathComponent)
        let outDir = options.output.map { $0.pathExtension.lowercased() == "exe" ? $0.deletingLastPathComponent() : $0 }
            ?? dir.appendingPathComponent("build/windows", isDirectory: true)
        let output = options.output.flatMap { $0.pathExtension.lowercased() == "exe" ? $0 : nil }
            ?? outDir.appendingPathComponent("\(baseName).exe")
        let arch = options.arch

        switch kind {
        case .go:
            var args = ["build", "-trimpath", "-o", output.path]
            if options.gui { args += ["-ldflags", "-H windowsgui -s -w"] } else { args += ["-ldflags", "-s -w"] }
            args.append(isDir.boolValue ? "." : project.lastPathComponent)
            return BuildPlan(kind: kind, project: project, steps: [
                BuildStep(title: "go build", tool: "go", arguments: args,
                          environment: ["GOOS": "windows", "GOARCH": arch.goArch, "CGO_ENABLED": "0"],
                          directory: dir),
            ], output: output, requirements: [("go", "brew install go")])

        case .c, .cpp:
            let cxx = kind == .cpp
            let compiler = "\(arch.mingwPrefix)-\(cxx ? "g++" : "gcc")"
            let sources = isDir.boolValue ? Self.cSources(in: dir).map(\.path) : [project.path]
            guard !sources.isEmpty else { throw BuildError.noEntryPoint("Không có file .c/.cpp trong \(dir.path).") }
            // -static: không phụ thuộc libgcc/libstdc++ DLL, copy sang máy Windows là chạy.
            var args = sources + ["-O2", "-static", "-o", output.path]
            if options.gui { args.append("-mwindows") }
            if cxx { args.insert("-std=c++17", at: 0) }
            return BuildPlan(kind: kind, project: project, steps: [
                BuildStep(title: "Biên dịch bằng MinGW-w64", tool: compiler, arguments: args, directory: dir),
            ], output: output, requirements: [(compiler, "brew install mingw-w64")])

        case .cmake:
            let buildDir = dir.appendingPathComponent("build/windows-cmake")
            let p = arch.mingwPrefix
            return BuildPlan(kind: kind, project: project, steps: [
                BuildStep(title: "cmake configure", tool: "cmake", arguments: [
                    "-S", dir.path, "-B", buildDir.path,
                    "-DCMAKE_SYSTEM_NAME=Windows",
                    "-DCMAKE_C_COMPILER=\(p)-gcc", "-DCMAKE_CXX_COMPILER=\(p)-g++",
                    "-DCMAKE_RC_COMPILER=\(p)-windres",
                    "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER",
                    "-DCMAKE_BUILD_TYPE=Release",
                    "-DCMAKE_EXE_LINKER_FLAGS=-static",
                ], directory: dir),
                BuildStep(title: "cmake build", tool: "cmake",
                          arguments: ["--build", buildDir.path, "--config", "Release", "--parallel"], directory: dir),
            ], output: buildDir, requirements: [("cmake", "brew install cmake"), ("\(p)-gcc", "brew install mingw-w64")],
               collectTo: outDir)

        case .rust:
            // Ưu tiên cargo-xwin (target MSVC, giống build trên Windows nhất); nếu không có thì dùng GNU + MinGW.
            let release = ["--release"]
            if Shell.which("cargo-xwin") != nil {
                return BuildPlan(kind: kind, project: project, steps: [
                    BuildStep(title: "cargo xwin build", tool: "cargo",
                              arguments: ["xwin", "build", "--target", arch.rustMSVC] + release, directory: dir),
                ], output: dir.appendingPathComponent("target/\(arch.rustMSVC)/release"),
                   requirements: [("cargo", "curl https://sh.rustup.rs -sSf | sh")], collectTo: outDir)
            }
            let linker = "\(arch.mingwPrefix)-gcc"
            let envKey = "CARGO_TARGET_\(arch.rustGNU.uppercased().replacingOccurrences(of: "-", with: "_"))_LINKER"
            return BuildPlan(kind: kind, project: project, steps: [
                BuildStep(title: "cargo build", tool: "cargo",
                          arguments: ["build", "--target", arch.rustGNU] + release,
                          environment: [envKey: linker], directory: dir),
            ], output: dir.appendingPathComponent("target/\(arch.rustGNU)/release"),
               requirements: [("cargo", "curl https://sh.rustup.rs -sSf | sh"),
                              (linker, "brew install mingw-w64 (hoặc: cargo install cargo-xwin)")],
               collectTo: outDir)

        case .dotnet:
            var args = ["publish"]
            if !isDir.boolValue { args.append(project.path) }
            args += ["-c", "Release", "-r", arch.dotnetRID, "--self-contained", "true",
                     "-p:PublishSingleFile=true", "-p:IncludeNativeLibrariesForSelfExtract=true",
                     // Cho phép build WinForms/WPF từ máy không phải Windows.
                     "-p:EnableWindowsTargeting=true", "-o", outDir.path]
            return BuildPlan(kind: kind, project: project, steps: [
                BuildStep(title: "dotnet publish", tool: "dotnet", arguments: args, directory: dir),
            ], output: outDir, requirements: [("dotnet", "brew install --cask dotnet-sdk")])

        case .python:
            throw BuildError.noEntryPoint("Python build qua Wine — dùng PythonBuilder.")
        }
    }

    /// Kiểm tra công cụ còn thiếu trước khi chạy.
    public static func missingRequirements(_ plan: BuildPlan) -> [(tool: String, install: String)] {
        plan.requirements.filter { Shell.which($0.tool) == nil }
    }

    // MARK: Chạy

    /// Chạy kế hoạch, trả về file .exe tạo ra.
    public func execute(_ plan: BuildPlan, output: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        let missing = Self.missingRequirements(plan)
        guard missing.isEmpty else { throw BuildError.missingTools(missing) }
        if plan.kind == .rust, let target = plan.steps.first?.arguments.drop(while: { $0 != "--target" }).dropFirst().first,
           target.hasSuffix("-gnu") {
            let installed = (try? Shell.run(Shell.which("rustup")?.path ?? "/usr/bin/false", ["target", "list", "--installed"])) ?? ""
            if !installed.contains(target) { throw BuildError.missingRustTarget(target) }
        }

        let started = Date()
        try FileManager.default.createDirectory(
            at: plan.output.pathExtension == "exe" ? plan.output.deletingLastPathComponent() : plan.output,
            withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.searchPath
        for step in plan.steps {
            output?("▸ \(step.title)\n  $ \(step.commandLine)\n")
            guard let tool = Shell.which(step.tool) else { throw BuildError.missingTools([(step.tool, "")]) }
            let code = try await Shell.stream(tool, step.arguments,
                                              environment: env.merging(step.environment) { $1 },
                                              currentDirectory: step.directory, output: output)
            guard code == 0 else { throw BuildError.stepFailed(step.title, code) }
        }
        if plan.output.pathExtension == "exe" {
            guard FileManager.default.fileExists(atPath: plan.output.path) else { throw BuildError.noOutput(plan.output.path) }
            return plan.output
        }
        guard let exe = Self.newestExe(in: plan.output, since: started) else {
            throw BuildError.noOutput(plan.output.path)
        }
        guard let collect = plan.collectTo else { return exe }
        try FileManager.default.createDirectory(at: collect, withIntermediateDirectories: true)
        let dest = collect.appendingPathComponent(exe.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: exe, to: dest)
        return dest
    }

    /// File .exe mới nhất được tạo sau `since` (dùng cho CMake/Rust/.NET khi tên file do dự án quyết định).
    static func newestExe(in dir: URL, since: Date) -> URL? {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var best: (URL, Date)?
        for case let url as URL in walker where url.pathExtension.lowercased() == "exe" {
            // Bỏ qua file trong thư mục deps/build script của cargo và CMakeFiles.
            if url.path.contains("/deps/") || url.path.contains("/CMakeFiles/") || url.path.contains("/build/") && url.path.contains("/out/") { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard date >= since.addingTimeInterval(-2) else { continue }
            if best == nil || date > best!.1 { best = (url, date) }
        }
        return best?.0
    }
}
