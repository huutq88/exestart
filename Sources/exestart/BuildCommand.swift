import ArgumentParser
import ExeStartKit
import Foundation

extension ProjectKind: ExpressibleByArgument {}
extension Arch: ExpressibleByArgument {}

struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build mã nguồn thành file .exe Windows ngay trên Mac.",
        discussion: """
        Tự nhận diện dự án theo file trong thư mục:
          go.mod → Go          Cargo.toml → Rust        CMakeLists.txt → C/C++ (CMake)
          *.c / *.cpp → C/C++  *.csproj / *.sln → .NET  *.py → Python (PyInstaller qua Wine)

        Ví dụ:
          exestart build                         # build thư mục hiện tại
          exestart build ./hello.c --gui --run   # app có cửa sổ, chạy thử ngay bằng Wine
          exestart build ./tool --lang go --arch x86 -o dist/tool32.exe
          exestart build ./app/main.py           # lần đầu tự cài Python Windows + PyInstaller
          exestart build --dry-run               # chỉ in lệnh sẽ chạy

        Kết quả mặc định nằm ở <dự án>/build/windows/.
        """)

    @Argument(help: "Thư mục dự án hoặc file nguồn (mặc định: thư mục hiện tại).") var path: String = "."
    @Option(name: .long, help: "Ngôn ngữ: \(ProjectKind.allCases.map(\.rawValue).joined(separator: ", ")).")
    var lang: ProjectKind?
    @Option(help: "Kiến trúc: x64 (mặc định) hoặc x86 (32-bit).") var arch: Arch = .x64
    @Option(name: .shortAndLong, help: "File .exe hoặc thư mục đầu ra.") var output: String?
    @Option(help: "Tên file .exe (không kèm đuôi).") var name: String?
    @Flag(help: "App có cửa sổ: không mở kèm cửa sổ console.") var gui = false
    @Flag(help: "Chạy thử file .exe bằng Wine sau khi build xong.") var run = false
    @Option(name: .shortAndLong, help: "Bottle dùng khi --run.") var bottle: String?
    @Flag(help: "Chỉ in các lệnh sẽ chạy, không build.") var dryRun = false

    func run() async throws {
        // stdout bị buffer khi pipe; tắt buffer để dòng của ExeStart và output của trình biên dịch đúng thứ tự.
        setvbuf(stdout, nil, _IONBF, 0)
        let project = expand(path)
        guard FileManager.default.fileExists(atPath: project.path) else { throw ExeStartError.fileNotFound(project.path) }
        let options = BuildOptions(kind: lang, arch: arch, gui: gui, output: output.map(expand), name: name)
        guard let kind = options.kind ?? Builder.detect(project) else { throw BuildError.unknownProject(project.path) }
        print("Dự án: \(kind.displayName) · \(arch.rawValue)\(gui ? " · GUI" : "")")

        let printer: @Sendable (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) }
        let exe: URL
        if kind == .python {
            if dryRun {
                let script = try PythonBuilder.entryPoint(for: project)
                print("Sẽ chạy PyInstaller cho \(script.path) trong bottle “\(PythonBuilder.bottleName)” (Python \(PythonBuilder.pythonVersion) bản Windows).")
                return
            }
            _ = try bottles.runtimes.runtime(id: nil)   // cần Wine trước
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
        print("✔ Đã build \(exe.path) \(size)")

        if run {
            // Python: chạy luôn trong bottle vừa build (đã có sẵn Python runtime nếu cần).
            let b = try resolveBottle(bottle ?? (kind == .python ? PythonBuilder.bottleName : nil))
            let wine = try bottles.wine(for: b)
            let (process, log) = try wine.launch(exe)
            print("▶ Chạy thử trong bottle '\(b.name)' · log: \(log.path)")
            process.waitUntilExit()
            if let text = try? String(contentsOf: log, encoding: .utf8), !text.isEmpty { print(text) }
        }
    }
}
