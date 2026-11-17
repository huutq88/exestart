import ArgumentParser
import ExeStartKit
import Foundation

@main
struct ExeStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exestart",
        abstract: "Chạy ứng dụng Windows trên macOS bằng Wine — không cần máy ảo.",
        discussion: """
        Bắt đầu nhanh:
          exestart runtime install          # tải Wine (một lần)
          exestart bottle create Office     # tạo môi trường Windows riêng
          exestart run ~/Downloads/setup.exe --bottle Office

        Build .exe từ mã nguồn ngay trên Mac:
          exestart build ./my-go-app --run
        """,
        subcommands: [Run.self, Build.self, RuntimeCmd.self, BottleCmd.self, Programs.self,
                      Tricks.self, Tool.self, Shortcut.self, Kill.self, Doctor.self]
    )
}

// MARK: - Tiện ích

let bottles = BottleManager()

func resolveBottle(_ name: String?) throws -> Bottle {
    if let name { return try bottles.bottle(named: name) }
    let all = bottles.list()
    if all.count == 1 { return all[0] }
    if let def = all.first(where: { $0.name == "Default" }) { return def }
    if all.isEmpty {
        print("Chưa có bottle nào — tạo bottle 'Default'...")
        return try bottles.create(name: "Default")
    }
    throw ValidationError("Có nhiều bottle, hãy chọn bằng --bottle <tên>. Danh sách: "
                          + all.map(\.name).joined(separator: ", "))
}

func expand(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

final class ProgressBar: @unchecked Sendable {
    private var last = -1
    func update(_ label: String, _ value: Double?) {
        guard let value else { print("\r\u{1B}[K\(label)…"); last = -1; return }
        let pct = Int(value * 100)
        guard pct != last else { return }
        last = pct
        let width = 30
        let filled = Int(Double(width) * value)
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        print("\r\u{1B}[K\(label) \(bar) \(pct)%", terminator: pct >= 100 ? "\n" : "")
        fflush(stdout)
    }
}

// MARK: - run

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Chạy một file .exe/.msi/.bat/.lnk.")

    @Argument(help: "Đường dẫn tới file Windows.") var file: String
    @Option(name: .shortAndLong, help: "Tên bottle.") var bottle: String?
    @Flag(name: .shortAndLong, help: "Chạy nền, không chờ chương trình đóng.") var detach = false
    @Flag(name: .shortAndLong, help: "Bật log Wine chi tiết để gỡ lỗi.") var verbose = false
    @Argument(parsing: .postTerminator, help: "Tham số truyền cho chương trình (sau --).") var args: [String] = []

    func run() async throws {
        let b = try resolveBottle(bottle)
        var wine = try bottles.wine(for: b)
        wine.verbose = verbose
        let url = expand(file)
        let (process, log) = try wine.launch(url, arguments: args)
        print("▶ \(url.lastPathComponent) trong bottle '\(b.name)' (\(wine.runtime.displayName))")
        print("  Log: \(log.path)")
        if detach { return }
        process.waitUntilExit()
        // .exe cài đặt thường sinh tiến trình con; chờ wineserver để biết mọi thứ đã xong.
        wine.waitServer()
        if process.terminationStatus != 0 {
            print("Chương trình thoát với mã \(process.terminationStatus). Xem log ở trên.")
        }
    }
}

// MARK: - runtime

struct RuntimeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime", abstract: "Quản lý các bản Wine.",
        subcommands: [List.self, Available.self, Install.self, Default.self, Remove.self],
        defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Liệt kê Wine đã cài.")
        func run() async throws {
            let mgr = bottles.runtimes
            let all = mgr.installed()
            if all.isEmpty { print("Chưa cài Wine. Chạy: exestart runtime install"); return }
            let def = (try? mgr.runtime(id: nil))?.id
            for rt in all { print("\(rt.id == def ? "*" : " ") \(rt.id)\t\(rt.wineBinary.path)") }
        }
    }

    struct Available: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Liệt kê bản Wine có thể tải.")
        @Option(help: "Lọc theo kênh: stable, devel, staging.") var channel: String?
        @Option(help: "Số bản hiển thị.") var limit = 10
        func run() async throws {
            let list = try await bottles.runtimes.available()
                .filter { channel == nil || $0.channel == channel }
            for r in list.prefix(limit) { print("\(r.id)\t\(r.sizeText)") }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Tải và cài Wine (mặc định: bản stable mới nhất).")
        @Argument(help: "Id runtime, vd. wine-stable-11.0_1 hoặc wine-devel-11.21.") var id: String?
        @Option(help: "Kênh khi không chỉ định id: stable, devel, staging.") var channel = "stable"
        func run() async throws {
            let mgr = bottles.runtimes
            let list = try await mgr.available()
            let pick = id.map { id in list.first { $0.id == id } }
                ?? list.first { $0.channel == channel }
            guard let pick = pick ?? nil else {
                throw ValidationError("Không tìm thấy bản phù hợp. Xem: exestart runtime available")
            }
            let bar = ProgressBar()
            let rt = try await mgr.install(pick) { label, p in bar.update(label, p) }
            print("✔ Đã cài \(rt.displayName)")
        }
    }

    struct Default: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Đặt runtime mặc định.")
        @Argument var id: String
        func run() async throws { try bottles.runtimes.setDefault(id); print("✔ Mặc định: \(id)") }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Xoá một runtime đã cài.")
        @Argument var id: String
        func run() async throws { try bottles.runtimes.remove(id: id); print("✔ Đã xoá \(id)") }
    }
}

// MARK: - bottle

struct BottleCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottle", abstract: "Quản lý bottle (mỗi bottle là một ổ C: Windows riêng).",
        subcommands: [List.self, Create.self, Delete.self, Info.self, SetCmd.self, Open.self],
        defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Liệt kê bottle.")
        func run() async throws {
            let all = bottles.list()
            if all.isEmpty { print("Chưa có bottle. Tạo: exestart bottle create <tên>"); return }
            for b in all {
                let rt = b.config.runtimeID ?? "mặc định"
                print("\(b.name)\t\(b.config.windowsVersion.displayName)\t\(rt)")
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Tạo bottle mới.")
        @Argument var name: String
        @Option(help: "Phiên bản Windows: \(WindowsVersion.allCases.map(\.rawValue).joined(separator: ", ")).")
        var windows = "win10"
        @Option(help: "Id runtime (mặc định: runtime mặc định).") var runtime: String?
        func run() async throws {
            guard let v = WindowsVersion(rawValue: windows) else { throw ValidationError("Sai --windows") }
            print("Đang tạo bottle '\(name)' (lần đầu mất khoảng 30–60 giây)…")
            let b = try bottles.create(name: name, runtimeID: runtime, windowsVersion: v)
            print("✔ Đã tạo: \(b.directory.path)")
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Chuyển bottle vào Thùng rác.")
        @Argument var name: String
        @Flag(name: .shortAndLong, help: "Không hỏi lại.") var yes = false
        func run() async throws {
            let b = try bottles.bottle(named: name)
            if !yes {
                print("Chuyển bottle '\(name)' và mọi chương trình trong đó vào Thùng rác? [y/N] ", terminator: "")
                guard readLine()?.lowercased() == "y" else { print("Đã huỷ."); return }
            }
            try bottles.delete(b)
            print("✔ Đã chuyển vào Thùng rác.")
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Xem thông tin bottle.")
        @Argument var name: String?
        func run() async throws {
            let b = try resolveBottle(name)
            let wine = try? bottles.wine(for: b)
            print("""
            Tên:        \(b.name)
            Thư mục:    \(b.directory.path)
            Ổ C:        \(b.driveC.path)
            Runtime:    \(wine?.runtime.displayName ?? "chưa cài")
            Windows:    \(b.config.windowsVersion.displayName)
            Retina:     \(b.config.retinaMode ? "bật" : "tắt")
            DPI:        \(b.config.dpi)
            Đang chạy:  \(wine?.isRunning == true ? "có" : "không")
            """)
            if !b.config.environment.isEmpty {
                print("Biến môi trường:")
                b.config.environment.sorted { $0.key < $1.key }.forEach { print("  \($0.key)=\($0.value)") }
            }
        }
    }

    struct SetCmd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Đổi cấu hình bottle.")
        @Argument var name: String
        @Option(help: "Phiên bản Windows.") var windows: String?
        @Option(help: "Retina mode: on/off.") var retina: String?
        @Option(help: "DPI (96 = 100%, 144 = 150%, 192 = 200%).") var dpi: Int?
        @Option(help: "Id runtime.") var runtime: String?
        @Option(name: .customLong("env"), help: "Biến môi trường KEY=VALUE (KEY= để xoá).") var env: [String] = []

        func run() async throws {
            var b = try bottles.bottle(named: name)
            if let runtime { _ = try bottles.runtimes.runtime(id: runtime); b.config.runtimeID = runtime }
            for pair in env {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = parts.first, !key.isEmpty else { throw ValidationError("Sai --env \(pair)") }
                let value = parts.count > 1 ? parts[1] : ""
                b.config.environment[key] = value.isEmpty ? nil : value
            }
            let wine = try bottles.wine(for: b)
            if let windows {
                guard let v = WindowsVersion(rawValue: windows) else { throw ValidationError("Sai --windows") }
                try wine.setWindowsVersion(v); b.config.windowsVersion = v
            }
            if let retina {
                let on = ["on", "y", "yes", "1", "true"].contains(retina.lowercased())
                try wine.setRetinaMode(on); b.config.retinaMode = on
            }
            if let dpi { try wine.setDPI(dpi); b.config.dpi = dpi }
            try b.save()
            print("✔ Đã lưu.")
        }
    }

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Mở ổ C: của bottle trong Finder.")
        @Argument var name: String?
        func run() async throws {
            let b = try resolveBottle(name)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [b.driveC.path]
            try p.run()
        }
    }
}

// MARK: - programs

struct Programs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Liệt kê chương trình đã cài trong bottle.")
    @Option(name: .shortAndLong) var bottle: String?
    func run() async throws {
        let b = try resolveBottle(bottle)
        let list = bottles.programs(in: b)
        if list.isEmpty { print("Chưa có chương trình nào trong '\(b.name)'."); return }
        for p in list { print("\(p.name)\t\(p.url.path)") }
    }
}

// MARK: - tricks

struct Tricks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tricks", abstract: "Cài thư viện Windows bằng winetricks (vcrun2022, dotnet48, corefonts…).")
    @Argument(help: "Tên gói winetricks. Bỏ trống để xem gói hay dùng.") var verbs: [String] = []
    @Option(name: .shortAndLong) var bottle: String?

    func run() async throws {
        if verbs.isEmpty {
            print("Gói hay dùng:")
            for item in Winetricks.common { print("  \(item.verb.padding(toLength: 16, withPad: " ", startingAt: 0)) \(item.title)") }
            print("\nVí dụ: exestart tricks corefonts vcrun2022 --bottle Office")
            return
        }
        let missing = Winetricks.missingTools
        if !missing.isEmpty {
            print("⚠ Thiếu \(missing.joined(separator: ", ")). Nhiều gói cần nó: brew install \(missing.joined(separator: " "))")
        }
        let b = try resolveBottle(bottle)
        let wine = try bottles.wine(for: b)
        let code = try await Winetricks().run(verbs, wine: wine) { chunk in
            FileHandle.standardOutput.write(Data(chunk.utf8))
        }
        if code != 0 { throw ExitCode(code) }
        print("✔ Xong.")
    }
}

// MARK: - tool

struct Tool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mở công cụ Wine: \(WineTool.allCases.map(\.rawValue).joined(separator: ", ")).")
    @Argument var tool: String
    @Option(name: .shortAndLong) var bottle: String?
    func run() async throws {
        guard let t = WineTool(rawValue: tool) else { throw ValidationError("Không có công cụ '\(tool)'.") }
        try bottles.wine(for: try resolveBottle(bottle)).openTool(t)
    }
}

// MARK: - shortcut

struct Shortcut: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tạo app .app trong ~/Applications/ExeStart để mở chương trình như app Mac.")
    @Argument(help: "File .exe/.lnk trong bottle.") var file: String
    @Option(name: .shortAndLong) var bottle: String?
    @Option(name: .shortAndLong, help: "Tên app (mặc định: tên file).") var name: String?
    func run() async throws {
        let url = expand(file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ExeStartError.fileNotFound(url.path) }
        let wine = try bottles.wine(for: try resolveBottle(bottle))
        let app = try ExeStartKit.Shortcut.create(
            name: name ?? url.deletingPathExtension().lastPathComponent, program: url, wine: wine)
        print("✔ Đã tạo \(app.path)")
    }
}

// MARK: - kill

struct Kill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tắt mọi chương trình Windows trong bottle.")
    @Option(name: .shortAndLong) var bottle: String?
    @Flag(help: "Tắt ở tất cả bottle.") var all = false
    func run() async throws {
        let targets = all ? bottles.list() : [try resolveBottle(bottle)]
        for b in targets { try? bottles.wine(for: b).kill(); print("✔ Đã tắt '\(b.name)'.") }
    }
}

// MARK: - doctor

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Kiểm tra máy đã sẵn sàng chạy Wine chưa.")
    func run() async throws {
        func line(_ ok: Bool, _ text: String, _ fix: String? = nil) {
            print("\(ok ? "✔" : "✘") \(text)")
            if !ok, let fix { print("    → \(fix)") }
        }
        #if arch(arm64)
        let rosetta = FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
        line(rosetta, "Rosetta 2", "softwareupdate --install-rosetta --agree-to-license")
        #endif
        let runtimes = bottles.runtimes.installed()
        line(!runtimes.isEmpty, "Wine runtime (\(runtimes.map(\.id).joined(separator: ", ")))", "exestart runtime install")
        if let rt = try? bottles.runtimes.runtime(id: nil),
           let version = try? Process.output(rt.wineBinary.path, ["--version"]) {
            print("    \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let missing = Winetricks.missingTools
        line(missing.isEmpty, "cabextract (cho winetricks)", "brew install cabextract")
        line(true, "Thư mục dữ liệu: \(Paths.shared.root.path)")
    }
}

extension Process {
    static func output(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

