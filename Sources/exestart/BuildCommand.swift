import ArgumentParser
import ExeStartKit
import Foundation

extension ProjectKind: ExpressibleByArgument {}
extension Arch: ExpressibleByArgument {}

struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build source code into a Windows .exe right on your Mac.",
        discussion: """
        Detects the project type from the files in the folder:
          go.mod → Go          Cargo.toml → Rust        CMakeLists.txt → C/C++ (CMake)
          *.c / *.cpp → C/C++  *.csproj / *.sln → .NET  *.py → Python (PyInstaller)

        Examples:
          exestart build                         # build the current folder
          exestart build ./hello.c --gui --run   # windowed app, test-run in Wine
          exestart build ./tool --lang go --arch x86 -o dist/tool32.exe
          exestart build ./app/main.py           # installs Windows Python on 1st run
          exestart build --dry-run               # only print the commands

        Output goes to <project>/build/windows/ by default.
        """)

    @Argument(help: "Project folder or source file (default: current folder).") var path: String = "."
    @Option(name: .long, help: "Language: \(ProjectKind.allCases.map(\.rawValue).joined(separator: ", ")).")
    var lang: ProjectKind?
    @Option(help: "Architecture: x64 (default) or x86 (32-bit).") var arch: Arch = .x64
    @Option(name: .shortAndLong, help: "Output .exe file or folder.") var output: String?
    @Option(help: "Name of the .exe file (without extension).") var name: String?
    @Flag(help: "Windowed app: don't open a console window.") var gui = false
    @Flag(help: "Test-run the .exe in Wine after the build.") var run = false
    @Option(name: .shortAndLong, help: "Bottle to use with --run.") var bottle: String?
    @Flag(help: "Only print the commands that would run; don't build.") var dryRun = false

    func run() async throws {
        // stdout is buffered when piped; disable buffering so ExeStart's lines and compiler output stay in order.
        setvbuf(stdout, nil, _IONBF, 0)
        let project = expand(path)
        guard FileManager.default.fileExists(atPath: project.path) else { throw ExeStartError.fileNotFound(project.path) }
        let options = BuildOptions(kind: lang, arch: arch, gui: gui, output: output.map(expand), name: name)
        guard let kind = options.kind ?? Builder.detect(project) else { throw BuildError.unknownProject(project.path) }
        print("Project: \(kind.displayName) · \(arch.rawValue)\(gui ? " · GUI" : "")")

        let printer: @Sendable (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) }
        let exe: URL
        if kind == .python {
            if dryRun {
                let script = try PythonBuilder.entryPoint(for: project)
                print("Would run PyInstaller on \(script.path) in bottle “\(PythonBuilder.bottleName)” (Windows Python \(PythonBuilder.pythonVersion)).")
                return
            }
            _ = try bottles.runtimes.runtime(id: nil)   // Wine is required first
            exe = try await PythonBuilder(bottles: bottles).build(project, options: options, output: printer)
        } else {
            var opts = options
            opts.kind = kind
            let plan = try Builder().plan(project, options: opts)
            let missing = Builder.missingRequirements(plan)
            if dryRun {
                plan.steps.forEach { print("$ \($0.commandLine)") }
                if !missing.isEmpty { print("\n" + (BuildError.missingTools(missing).errorDescription ?? "")) }
                return
            }
            exe = try await Builder().execute(plan, output: printer)
        }

        let size = (try? exe.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? ""
        print("✔ Built \(exe.path) \(size)")

        if run {
            // Python: run in the bottle used for the build (it already has the Python runtime if needed).
            let b = try resolveBottle(bottle ?? (kind == .python ? PythonBuilder.bottleName : nil))
            let wine = try bottles.wine(for: b)
            let (process, log) = try wine.launch(exe)
            print("▶ Test-running in bottle '\(b.name)' · log: \(log.path)")
            process.waitUntilExit()
            if let text = try? String(contentsOf: log, encoding: .utf8), !text.isEmpty { print(text) }
        }
    }
}
