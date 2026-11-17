import AppKit
import ExeStartKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var queued: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched via `swift run` (no bundle), still show in the Dock and take focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        flush()
    }

    /// Finder: "Open With → ExeStart", or a .exe dropped onto the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        queued += urls
        flush()
    }

    func attach(_ model: AppModel) {
        self.model = model
        flush()
    }

    private func flush() {
        guard let model, !queued.isEmpty else { return }
        let urls = queued
        queued.removeAll()
        Task { @MainActor in urls.forEach(model.open) }
    }
}

@main
struct ExeStartApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("ExeStart") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 540)
                .onAppear { delegate.attach(model) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Run Windows Program…") {
                    if let b = model.selectedBottle { model.chooseFile(for: b) }
                }
                .keyboardShortcut("o")
                .disabled(model.selectedBottle == nil)
            }
        }
    }
}
