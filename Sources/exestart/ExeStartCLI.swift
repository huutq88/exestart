import ArgumentParser
import ExeStartKit
import Foundation

@main
struct ExeStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exestart",
        abstract: "Run Windows apps on macOS with Wine — no virtual machine needed.",
        discussion: """
        Quick start:
          exestart runtime install          # download Wine (once)
          exestart bottle create Office     # create a separate Windows environment
          exestart run ~/Downloads/setup.exe --bottle Office

        Build an .exe from source right on your Mac:
          exestart build ./my-go-app --run
        """,
        subcommands: [Run.self, Build.self, RuntimeCmd.self, BottleCmd.self, Programs.self,
                      Tricks.self, Tool.self, Shortcut.self, Kill.self, Doctor.self]
    )
}

// MARK: - Helpers

let bottles = BottleManager()

func resolveBottle(_ name: String?) throws -> Bottle {
    if let name { return try bottles.bottle(named: name) }
    let all = bottles.list()
    if all.count == 1 { return all[0] }
    if let def = all.first(where: { $0.name == "Default" }) { return def }
    if all.isEmpty {
        print("No bottles yet — creating bottle 'Default'...")
        return try bottles.create(name: "Default")
    }
    throw ValidationError("There are several bottles; pick one with --bottle <name>. Available: "
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
        abstract: "Run an .exe/.msi/.bat/.lnk file.")

    @Argument(help: "Path to the Windows file.") var file: String
    @Option(name: .shortAndLong, help: "Bottle name.") var bottle: String?
    @Flag(name: .shortAndLong, help: "Run in the background; don't wait for the program to exit.") var detach = false
    @Flag(name: .shortAndLong, help: "Enable verbose Wine logging for debugging.") var verbose = false
    @Argument(parsing: .postTerminator, help: "Arguments passed to the program (after --).") var args: [String] = []

    func run() async throws {
        let b = try resolveBottle(bottle)
        var wine = try bottles.wine(for: b)
        wine.verbose = verbose
        let url = expand(file)
        let (process, log) = try wine.launch(url, arguments: args)
        print("▶ \(url.lastPathComponent) in bottle '\(b.name)' (\(wine.runtime.displayName))")
        print("  Log: \(log.path)")
        if detach { return }
        process.waitUntilExit()
        // Installers often spawn child processes; wait for wineserver to know everything has finished.
        wine.waitServer()
        if process.terminationStatus != 0 {
            print("Program exited with code \(process.terminationStatus). See the log above.")
        }
    }
}

// MARK: - runtime

struct RuntimeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime", abstract: "Manage Wine runtimes.",
        subcommands: [List.self, Available.self, Install.self, Default.self, Remove.self],
        defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List installed Wine runtimes.")
        func run() async throws {
            let mgr = bottles.runtimes
            let all = mgr.installed()
            if all.isEmpty { print("Wine is not installed. Run: exestart runtime install"); return }
            let def = (try? mgr.runtime(id: nil))?.id
            for rt in all { print("\(rt.id == def ? "*" : " ") \(rt.id)\t\(rt.wineBinary.path)") }
        }
    }

    struct Available: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List Wine runtimes available to download.")
        @Option(help: "Filter by channel: stable, devel, staging.") var channel: String?
        @Option(help: "Number of runtimes to show.") var limit = 10
        func run() async throws {
            let list = try await bottles.runtimes.available()
                .filter { channel == nil || $0.channel == channel }
            for r in list.prefix(limit) { print("\(r.id)\t\(r.sizeText)") }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download and install Wine (default: latest stable).")
        @Argument(help: "Runtime ID, e.g. wine-stable-11.0_1 or wine-devel-11.21.") var id: String?
        @Option(help: "Channel to use when no ID is given: stable, devel, staging.") var channel = "stable"
        func run() async throws {
            let mgr = bottles.runtimes
            let list = try await mgr.available()
            let pick = id.map { id in list.first { $0.id == id } }
                ?? list.first { $0.channel == channel }
            guard let pick = pick ?? nil else {
                throw ValidationError("No matching runtime found. See: exestart runtime available")
            }
            let bar = ProgressBar()
            let rt = try await mgr.install(pick) { label, p in bar.update(label, p) }
            print("✔ Installed \(rt.displayName)")
        }
    }

    struct Default: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set the default runtime.")
        @Argument var id: String
        func run() async throws { try bottles.runtimes.setDefault(id); print("✔ Default: \(id)") }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an installed runtime.")
        @Argument var id: String
        func run() async throws { try bottles.runtimes.remove(id: id); print("✔ Removed \(id)") }
    }
}

// MARK: - bottle

struct BottleCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottle", abstract: "Manage bottles (each bottle is a separate Windows C: drive).",
        subcommands: [List.self, Create.self, Delete.self, Info.self, SetCmd.self, Open.self],
        defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List bottles.")
        func run() async throws {
            let all = bottles.list()
            if all.isEmpty { print("No bottles yet. Create one: exestart bottle create <name>"); return }
            for b in all {
                let rt = b.config.runtimeID ?? "default"
                print("\(b.name)\t\(b.config.windowsVersion.displayName)\t\(rt)")
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new bottle.")
        @Argument var name: String
        @Option(help: "Windows version: \(WindowsVersion.allCases.map(\.rawValue).joined(separator: ", ")).")
        var windows = "win10"
        @Option(help: "Runtime ID (default: the default runtime).") var runtime: String?
        func run() async throws {
            guard let v = WindowsVersion(rawValue: windows) else { throw ValidationError("Invalid --windows value") }
            print("Creating bottle '\(name)' (takes about 30–60 seconds the first time)…")
            let b = try bottles.create(name: name, runtimeID: runtime, windowsVersion: v)
            print("✔ Created: \(b.directory.path)")
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move a bottle to the Trash.")
        @Argument var name: String
        @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false
        func run() async throws {
            let b = try bottles.bottle(named: name)
            if !yes {
                print("Move bottle '\(name)' and all programs in it to the Trash? [y/N] ", terminator: "")
                guard ["y", "yes"].contains(readLine()?.lowercased() ?? "") else { print("Cancelled."); return }
            }
            try bottles.delete(b)
            print("✔ Moved to the Trash.")
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show bottle details.")
        @Argument var name: String?
        func run() async throws {
            let b = try resolveBottle(name)
            let wine = try? bottles.wine(for: b)
            print("""
            Name:       \(b.name)
            Folder:     \(b.directory.path)
            Drive C:    \(b.driveC.path)
            Runtime:    \(wine?.runtime.displayName ?? "not installed")
            Windows:    \(b.config.windowsVersion.displayName)
            Retina:     \(b.config.retinaMode ? "on" : "off")
            DPI:        \(b.config.dpi)
            Running:    \(wine?.isRunning == true ? "yes" : "no")
            """)
            if !b.config.environment.isEmpty {
                print("Environment variables:")
                b.config.environment.sorted { $0.key < $1.key }.forEach { print("  \($0.key)=\($0.value)") }
            }
        }
    }

    struct SetCmd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Change bottle settings.")
        @Argument var name: String
        @Option(help: "Windows version.") var windows: String?
        @Option(help: "Retina mode: on/off.") var retina: String?
        @Option(help: "DPI (96 = 100%, 144 = 150%, 192 = 200%).") var dpi: Int?
        @Option(help: "Runtime ID.") var runtime: String?
        @Option(name: .customLong("env"), help: "Environment variable KEY=VALUE (KEY= to remove).") var env: [String] = []

        func run() async throws {
            var b = try bottles.bottle(named: name)
            if let runtime { _ = try bottles.runtimes.runtime(id: runtime); b.config.runtimeID = runtime }
            for pair in env {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = parts.first, !key.isEmpty else { throw ValidationError("Invalid --env value: \(pair)") }
                let value = parts.count > 1 ? parts[1] : ""
                b.config.environment[key] = value.isEmpty ? nil : value
            }
            let wine = try bottles.wine(for: b)
            if let windows {
                guard let v = WindowsVersion(rawValue: windows) else { throw ValidationError("Invalid --windows value") }
                try wine.setWindowsVersion(v); b.config.windowsVersion = v
            }
            if let retina {
                let on = ["on", "y", "yes", "1", "true"].contains(retina.lowercased())
                try wine.setRetinaMode(on); b.config.retinaMode = on
            }
            if let dpi { try wine.setDPI(dpi); b.config.dpi = dpi }
            try b.save()
            print("✔ Saved.")
        }
    }

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open the bottle's C: drive in Finder.")
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
    static let configuration = CommandConfiguration(abstract: "List programs installed in a bottle.")
    @Option(name: .shortAndLong) var bottle: String?
    func run() async throws {
        let b = try resolveBottle(bottle)
        let list = bottles.programs(in: b)
        if list.isEmpty { print("No programs in '\(b.name)' yet."); return }
        for p in list { print("\(p.name)\t\(p.url.path)") }
    }
}

// MARK: - tricks

struct Tricks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tricks", abstract: "Install Windows libraries with winetricks (vcrun2022, dotnet48, corefonts…).")
    @Argument(help: "Winetricks package names. Leave empty to list common packages.") var verbs: [String] = []
    @Option(name: .shortAndLong) var bottle: String?
    @Flag(name: .shortAndLong, help: "Install missing tools (cabextract) via Homebrew without asking.") var yes = false

    func run() async throws {
        if verbs.isEmpty {
            print("Common packages:")
            for item in Winetricks.common { print("  \(item.verb.padding(toLength: 16, withPad: " ", startingAt: 0)) \(item.title)") }
            print("\nExample: exestart tricks corefonts vcrun2022 --bottle Office")
            return
        }
        if !Winetricks.missingTools.isEmpty {
            try await offerWinetricksTools(assumeYes: yes)
        }
        let b = try resolveBottle(bottle)
        let wine = try bottles.wine(for: b)
        let code = try await Winetricks().run(verbs, wine: wine) { chunk in
            FileHandle.standardOutput.write(Data(chunk.utf8))
        }
        if code != 0 { throw ExitCode(code) }
        print("✔ Done.")
    }
}

// MARK: - tool

struct Tool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a Wine tool: \(WineTool.allCases.map(\.rawValue).joined(separator: ", ")).")
    @Argument var tool: String
    @Option(name: .shortAndLong) var bottle: String?
    func run() async throws {
        guard let t = WineTool(rawValue: tool) else { throw ValidationError("Unknown tool '\(tool)'.") }
        try bottles.wine(for: try resolveBottle(bottle)).openTool(t)
    }
}

// MARK: - shortcut

struct Shortcut: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a .app in ~/Applications/ExeStart to open a program like a Mac app.")
    @Argument(help: "The .exe/.lnk file in the bottle.") var file: String
    @Option(name: .shortAndLong) var bottle: String?
    @Option(name: .shortAndLong, help: "App name (default: the file name).") var name: String?
    func run() async throws {
        let url = expand(file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ExeStartError.fileNotFound(url.path) }
        let wine = try bottles.wine(for: try resolveBottle(bottle))
        let app = try ExeStartKit.Shortcut.create(
            name: name ?? url.deletingPathExtension().lastPathComponent, program: url, wine: wine)
        print("✔ Created \(app.path)")
    }
}

// MARK: - kill

struct Kill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop all Windows programs in a bottle.")
    @Option(name: .shortAndLong) var bottle: String?
    @Flag(help: "Stop programs in all bottles.") var all = false
    func run() async throws {
        let targets = all ? bottles.list() : [try resolveBottle(bottle)]
        for b in targets { try? bottles.wine(for: b).kill(); print("✔ Stopped '\(b.name)'.") }
    }
}

// MARK: - doctor

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check whether this Mac is ready to run Wine (--fix installs what's missing).")
    @Flag(help: "Install what's missing: Wine runtime, cabextract (via Homebrew).") var fix = false
    @Flag(name: .shortAndLong, help: "With --fix: don't ask for confirmation.") var yes = false

    func run() async throws {
        if fix { try await repair() }
        report()
    }

    private func report() {
        func line(_ ok: Bool, _ text: String, _ fix: String? = nil) {
            print("\(ok ? "✔" : "✘") \(text)")
            if !ok, let fix { print("    → \(fix)") }
        }
        #if arch(arm64)
        line(rosettaInstalled, "Rosetta 2", "softwareupdate --install-rosetta --agree-to-license")
        #endif
        let runtimes = bottles.runtimes.installed()
        line(!runtimes.isEmpty, "Wine runtime (\(runtimes.map(\.id).joined(separator: ", ")))", "exestart doctor --fix")
        if let rt = try? bottles.runtimes.runtime(id: nil),
           let version = try? Process.output(rt.wineBinary.path, ["--version"]) {
            print("    \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        line(Winetricks.missingTools.isEmpty, "cabextract (for winetricks)",
             Homebrew.isInstalled ? "exestart doctor --fix" : "Install Homebrew (\(Homebrew.website)), then: brew install cabextract")
        line(true, "Data folder: \(Paths.shared.root.path)")
    }

    private var rosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    private func repair() async throws {
        var changed = false
        #if arch(arm64)
        if !rosettaInstalled {
            // Needs admin rights and accepting Apple's license — leave it to the user.
            print("Rosetta 2 needs admin rights; run this yourself: softwareupdate --install-rosetta --agree-to-license\n")
        }
        #endif
        if bottles.runtimes.installed().isEmpty {
            let list = try await bottles.runtimes.available()
            if let pick = list.first(where: { $0.channel == "stable" }),
               yes || confirm("Download and install \(pick.id) (\(pick.sizeText) from GitHub)?") {
                let bar = ProgressBar()
                try await bottles.runtimes.install(pick) { label, p in bar.update(label, p) }
                changed = true
            }
        }
        if !Winetricks.missingTools.isEmpty {
            try await offerWinetricksTools(assumeYes: yes)
            changed = true
        }
        print(changed ? "" : "Nothing to fix.\n")
    }
}

/// Asks a y/N question in the terminal. Without a terminal (e.g. in a script), the answer is "no".
func confirm(_ question: String) -> Bool {
    guard isatty(STDIN_FILENO) != 0 else { return false }
    print("\(question) [y/N] ", terminator: "")
    fflush(stdout)
    return ["y", "yes"].contains(readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? "")
}

/// cabextract is missing: ask, then install it via Homebrew. Never blocks the command if the user declines.
func offerWinetricksTools(assumeYes: Bool) async throws {
    let missing = Winetricks.missingTools
    let names = missing.joined(separator: ", ")
    guard Homebrew.isInstalled else {
        print("⚠ Missing \(names) — many winetricks packages will fail. Install Homebrew (\(Homebrew.website)), then run: brew install \(missing.joined(separator: " "))")
        return
    }
    guard assumeYes || confirm("Missing \(names) (winetricks needs it to extract .cab files). Install with Homebrew?") else {
        print("Skipped. Install it later with: brew install \(missing.joined(separator: " "))")
        return
    }
    let ok = try await Homebrew.installWinetricksTools { FileHandle.standardOutput.write(Data($0.utf8)) }
    print(ok ? "✔ Installed \(names)." : "⚠ Install finished, but \(names) is still not on PATH.")
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

