import AppKit
import ExeStartKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var queued: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Khi chạy bằng `swift run` (không có bundle) app vẫn hiện Dock và nhận focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        flush()
    }

    /// Finder: "Open With → ExeStart" hoặc kéo .exe lên icon Dock.
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
                Button("Chạy file Windows…") {
                    if let b = model.selectedBottle { model.chooseFile(for: b) }
                }
                .keyboardShortcut("o")
                .disabled(model.selectedBottle == nil)
            }
        }
    }
}
