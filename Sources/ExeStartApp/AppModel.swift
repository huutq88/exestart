import AppKit
import ExeStartKit
import Foundation
import SwiftUI

/// Trạng thái dùng chung của app. Mọi thao tác nặng (Wine, mạng) chạy ngoài main thread.
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
    /// Bottle đang bận (tạo mới, đổi cấu hình...) — khoá nút để tránh bấm trùng.
    @Published var busy: Set<String> = []
    /// File mở từ Finder khi có nhiều bottle: hỏi người dùng chọn bottle.
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
            installState = .failed("Không lấy được danh sách Wine từ GitHub. Kiểm tra mạng rồi thử lại.\n(\(error.localizedDescription))")
        }
    }

    func installRuntime() async {
        if case .working = installState { return }   // chống bấm trùng
        if latestStable == nil { await fetchLatestStable() }
        guard let remote = latestStable else { return }
        installState = .working("Chuẩn bị tải", 0)
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
            show(.success, "Đã tạo bottle “\(b.name)”. Chạy file cài đặt .exe để bắt đầu.")
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
            show(.success, "Đã chuyển bottle “\(bottle.name)” vào Thùng rác. Có thể khôi phục từ Thùng rác.")
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    /// Ghi cấu hình rồi áp vào Wine (registry). Chạy nền vì wineserver có thể mất vài giây.
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
            show(.error, "Chưa lưu được thay đổi: \(error.localizedDescription)")
            reload()
        }
    }

    // MARK: Chạy chương trình

    func run(_ file: URL, in bottle: Bottle) {
        do {
            let wine = try manager.wine(for: bottle)
            let name = file.deletingPathExtension().lastPathComponent
            let (_, log) = try wine.launch(file) { code in
                guard code != 0 else { return }
                Task { @MainActor in
                    self.show(.error, "“\(name)” đã thoát với mã lỗi \(code). Xem log để biết nguyên nhân.", log: nil)
                }
            }
            show(.success, "Đang mở “\(name)” trong “\(bottle.name)”. Cửa sổ có thể mất vài giây để hiện.", log: log)
            // Chương trình cài đặt có thể tạo shortcut mới — làm mới danh sách sau ít lâu.
            Task { try? await Task.sleep(for: .seconds(8)); self.reload() }
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    /// Được gọi khi người dùng mở .exe từ Finder hoặc kéo vào cửa sổ.
    func open(_ file: URL) {
        if bottles.count == 1 { run(file, in: bottles[0]) } else { pendingFile = file }
    }

    func chooseFile(for bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.title = "Chọn chương trình Windows"
        panel.prompt = "Chạy"
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
            show(.success, "Đã tạo “\(program.name).app” trong ~/Applications/ExeStart.", log: nil)
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
        show(.success, "Đã tắt mọi chương trình trong “\(bottle.name)”.")
    }
}
