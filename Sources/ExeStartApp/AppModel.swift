import AppKit
import ExeStartKit
import Foundation
import SwiftUI

/// Shared app state. All heavy work (Wine, networking) runs off the main thread.
@MainActor
final class AppModel: ObservableObject {
    enum InstallState: Equatable {
        case idle
        case working(String, Double?)
        case failed(String)
    }

    struct Notice: Identifiable, Equatable {
        enum Kind { case success, error }
        let id = UUID()
        let kind: Kind
        let text: String
        var log: URL? = nil
    }

    let manager = BottleManager()

    @Published var runtimes: [Runtime] = []
    @Published var bottles: [Bottle] = []
    @Published var selection: Bottle.ID?
    @Published var installState: InstallState = .idle
    @Published var latestStable: RemoteRuntime?
    @Published var loadingRemote = false
    @Published var notice: Notice?
    /// Bottles that are busy (being created, reconfigured...) — disables buttons to prevent double clicks.
    @Published var busy: Set<String> = []
    /// File opened from Finder while there are several bottles: ask the user which bottle to use.
    @Published var pendingFile: URL?

    var selectedBottle: Bottle? { bottles.first { $0.id == selection } }

    init() { reload() }

    func reload() {
        runtimes = manager.runtimes.installed()
        bottles = manager.list()
        if selection == nil || !bottles.contains(where: { $0.id == selection }) {
            selection = bottles.first?.id
        }
    }

    func show(_ kind: Notice.Kind, _ text: String, log: URL? = nil) {
        notice = Notice(kind: kind, text: text, log: log)
    }

    // MARK: Runtime

    func fetchLatestStable() async {
        loadingRemote = true
        defer { loadingRemote = false }
        do {
            latestStable = try await manager.runtimes.available().first { $0.channel == "stable" }
            if case .failed = installState { installState = .idle }
        } catch {
            installState = .failed("Couldn’t get the list of Wine builds from GitHub. Check your internet connection and try again.\n(\(error.localizedDescription))")
        }
    }

    func installRuntime() async {
        if case .working = installState { return }   // prevent double clicks
        if latestStable == nil { await fetchLatestStable() }
        guard let remote = latestStable else { return }
        installState = .working("Preparing download", 0)
        do {
            try await manager.runtimes.install(remote) { label, p in
                Task { @MainActor in self.installState = .working(label, p) }
            }
            installState = .idle
            reload()
            if bottles.isEmpty { await createBottle(name: "Default", windows: .win10) }
        } catch {
            installState = .failed(error.localizedDescription)
        }
    }

    // MARK: Bottle

    @discardableResult
    func createBottle(name: String, windows: WindowsVersion) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        busy.insert(name)
        defer { busy.remove(name) }
        let mgr = manager
        do {
            let b = try await Task.detached { try mgr.create(name: name, windowsVersion: windows) }.value
            reload()
            selection = b.id
            show(.success, "Created bottle “\(b.name)”. Run a .exe installer to get started.")
            return true
        } catch {
            show(.error, error.localizedDescription)
            return false
        }
    }

    func delete(_ bottle: Bottle) {
        do {
            try manager.delete(bottle)
            reload()
            show(.success, "Moved bottle “\(bottle.name)” to the Trash. You can restore it from the Trash.")
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    /// Saves the configuration and applies it to Wine (registry). Runs in the background because wineserver can take a few seconds.
    func update(_ bottle: Bottle, apply: @escaping @Sendable (Wine) throws -> Void,
                change: (inout BottleConfig) -> Void) async {
        var b = bottle
        change(&b.config)
        busy.insert(b.name)
        defer { busy.remove(b.name) }
        let mgr = manager
        let copy = b
        do {
            try await Task.detached {
                let wine = try mgr.wine(for: copy)
                try apply(wine)
                try copy.save()
            }.value
            reload()
        } catch {
            show(.error, "Couldn’t save changes: \(error.localizedDescription)")
            reload()
        }
    }

    // MARK: Running programs

    func run(_ file: URL, in bottle: Bottle) {
        do {
            let wine = try manager.wine(for: bottle)
            let name = file.deletingPathExtension().lastPathComponent
            let (_, log) = try wine.launch(file) { code in
                guard code != 0 else { return }
                Task { @MainActor in
                    self.show(.error, "“\(name)” exited with code \(code). Check the log for details.", log: nil)
                }
            }
            show(.success, "Opening “\(name)” in “\(bottle.name)”. The window may take a few seconds to appear.", log: log)
            // Installers may create new shortcuts — refresh the list after a short delay.
            Task { try? await Task.sleep(for: .seconds(8)); self.reload() }
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    /// Called when the user opens a .exe from Finder or drops it onto the window.
    func open(_ file: URL) {
        if bottles.count == 1 { run(file, in: bottles[0]) } else { pendingFile = file }
    }

    func chooseFile(for bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows Program"
        panel.prompt = "Run"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { run(url, in: bottle) }
    }

    func createShortcut(_ program: Program, in bottle: Bottle) {
        do {
            let app = try Shortcut.create(name: program.name, program: program.url,
                                          wine: try manager.wine(for: bottle))
            show(.success, "Created “\(program.name).app” in ~/Applications/ExeStart.", log: nil)
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func togglePin(_ program: Program, in bottle: Bottle) {
        var b = bottle
        do {
            if b.config.pinned.contains(program.url.path) { try manager.unpin(program.url, in: &b) }
            else { try manager.pin(program.url, in: &b) }
            reload()
        } catch { show(.error, error.localizedDescription) }
    }

    func kill(_ bottle: Bottle) {
        let mgr = manager
        Task.detached { try? mgr.wine(for: bottle).kill() }
        show(.success, "Quit all programs in “\(bottle.name)”.")
    }
}
