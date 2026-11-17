import ExeStartKit
import SwiftUI

struct BottleDetailView: View {
    enum Tab: String, CaseIterable { case programs = "Chương trình", library = "Thư viện", settings = "Cài đặt" }

    @EnvironmentObject var model: AppModel
    let bottle: Bottle
    @State private var tab: Tab = .programs

    var body: some View {
        Group {
            switch tab {
            case .programs: ProgramsView(bottle: bottle)
            case .library: LibraryView(bottle: bottle)
            case .settings: BottleSettingsView(bottle: bottle)
            }
        }
        .navigationTitle(bottle.name)
        .navigationSubtitle(model.busy.contains(bottle.name) ? "Đang áp dụng thay đổi…" : bottle.config.windowsVersion.displayName)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mục", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.chooseFile(for: bottle) } label: {
                    Label("Chạy file .exe…", systemImage: "play.fill")
                }
                .help("Chọn file .exe, .msi, .bat hoặc .lnk để chạy trong bottle này (⌘O)")
            }
        }
    }
}

// MARK: - Chương trình

struct ProgramsView: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle
    @State private var programs: [Program] = []
    @State private var loaded = false
    @State private var query = ""

    private var filtered: [Program] {
        query.isEmpty ? programs : programs.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if !loaded {
                ProgressView("Đang tìm chương trình…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if programs.isEmpty {
                ContentUnavailableView {
                    Label("Chưa cài chương trình nào", systemImage: "square.and.arrow.down")
                } description: {
                    Text("Chạy file cài đặt (.exe hoặc .msi) — hoặc kéo thả file vào cửa sổ này. Sau khi cài, chương trình sẽ hiện ở đây.")
                } actions: {
                    Button("Chạy file cài đặt…") { model.chooseFile(for: bottle) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    if filtered.isEmpty {
                        Text("Không có chương trình khớp “\(query)”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { program in
                        ProgramRow(program: program, bottle: bottle,
                                   pinned: bottle.config.pinned.contains(program.url.path))
                    }
                }
                .searchable(text: $query, placement: .toolbar, prompt: "Tìm chương trình")
            }
        }
        .task(id: bottle) { await load() }
        .onReceive(model.$bottles) { _ in Task { await load() } }
    }

    private func load() async {
        let mgr = model.manager
        let b = bottle
        programs = await Task.detached { mgr.programs(in: b) }.value
        loaded = true
    }
}

struct ProgramRow: View {
    @EnvironmentObject var model: AppModel
    let program: Program
    let bottle: Bottle
    let pinned: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: program.url.path))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(program.name).font(.body.weight(.medium))
                    if pinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Đã ghim")
                    }
                }
                Text(windowsPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Mở") { model.run(program.url, in: bottle) }
                .accessibilityLabel("Mở \(program.name)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.run(program.url, in: bottle) }
        .contextMenu {
            Button("Mở") { model.run(program.url, in: bottle) }
            Button("Tạo app trong Launchpad") { model.createShortcut(program, in: bottle) }
            Button(pinned ? "Bỏ ghim" : "Ghim lên đầu") { model.togglePin(program, in: bottle) }
            Divider()
            Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([program.url]) }
        }
    }

    /// Hiện đường dẫn kiểu Windows (C:\...) cho quen mắt.
    private var windowsPath: String {
        let c = bottle.driveC.path
        guard program.url.path.hasPrefix(c) else { return program.url.path }
        return "C:" + program.url.path.dropFirst(c.count).replacingOccurrences(of: "/", with: "\\")
    }
}

// MARK: - Thư viện (winetricks)

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle
    @State private var running: String?
    @State private var log = ""
    @State private var lastResult: (verb: String, ok: Bool)?

    var body: some View {
        VStack(spacing: 0) {
            List {
                if !Winetricks.missingTools.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Thiếu cabextract — nhiều gói sẽ cài thất bại.")
                            Text("Mở Terminal và chạy: brew install cabextract").font(.callout).textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Section {
                    ForEach(Winetricks.common, id: \.verb) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.verb).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if running == item.verb {
                                ProgressView().controlSize(.small)
                                Text("Đang cài…").foregroundStyle(.secondary)
                            } else {
                                if let r = lastResult, r.verb == item.verb {
                                    Label(r.ok ? "Đã cài" : "Lỗi", systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                        .foregroundStyle(r.ok ? .green : .red)
                                }
                                Button("Cài") { install(item.verb) }
                                    .disabled(running != nil)
                            }
                        }
                    }
                } header: {
                    Text("Thư viện Windows hay cần")
                } footer: {
                    Text("Cài khi chương trình báo thiếu DLL, font lỗi hoặc cần .NET/Visual C++. Mỗi gói mất từ vài giây đến vài phút.")
                        .foregroundStyle(.secondary)
                }
            }
            if !log.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(log)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .id("end")
                    }
                    .frame(height: 160)
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: log) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .accessibilityLabel("Nhật ký cài đặt")
            }
        }
    }

    private func install(_ verb: String) {
        guard running == nil else { return }
        running = verb
        log = "$ winetricks \(verb)\n"
        let wine: Wine
        do { wine = try model.manager.wine(for: bottle) } catch {
            model.show(.error, error.localizedDescription); running = nil; return
        }
        Task {
            do {
                let code = try await Winetricks().run([verb], wine: wine) { chunk in
                    Task { @MainActor in
                        log += chunk
                        if log.count > 60_000 { log = String(log.suffix(40_000)) }
                    }
                }
                lastResult = (verb, code == 0)
                model.show(code == 0 ? .success : .error,
                           code == 0 ? "Đã cài \(verb) vào “\(bottle.name)”."
                                     : "Cài \(verb) thất bại (mã \(code)). Xem nhật ký bên dưới.")
            } catch {
                lastResult = (verb, false)
                model.show(.error, "Không chạy được winetricks: \(error.localizedDescription)")
            }
            running = nil
        }
    }
}

// MARK: - Cài đặt

struct BottleSettingsView: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle

    private var busy: Bool { model.busy.contains(bottle.name) }

    var body: some View {
        Form {
            Section("Windows") {
                Picker("Phiên bản Windows", selection: binding(\.windowsVersion) { wine, v in
                    try wine.setWindowsVersion(v)
                }) {
                    ForEach(WindowsVersion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Wine runtime", selection: Binding(
                    get: { bottle.config.runtimeID ?? "" },
                    set: { id in
                        Task { await model.update(bottle, apply: { _ in }) { $0.runtimeID = id.isEmpty ? nil : id } }
                    })) {
                    Text("Mặc định").tag("")
                    ForEach(model.runtimes) { Text($0.displayName).tag($0.id) }
                }
            }

            Section {
                Toggle("Retina mode", isOn: binding(\.retinaMode) { wine, on in try wine.setRetinaMode(on) })
                Picker("Cỡ chữ & giao diện", selection: binding(\.dpi) { wine, dpi in try wine.setDPI(dpi) }) {
                    Text("100% (96 DPI)").tag(96)
                    Text("125% (120 DPI)").tag(120)
                    Text("150% (144 DPI)").tag(144)
                    Text("200% (192 DPI)").tag(192)
                }
            } header: {
                Text("Hiển thị")
            } footer: {
                Text("Retina làm chữ nét hơn nhưng cửa sổ nhỏ lại — tăng tỉ lệ lên 150–200% để bù. Đóng và mở lại chương trình để thấy thay đổi.")
                    .foregroundStyle(.secondary)
            }

            Section("Công cụ Windows") {
                LabeledContent("Ổ C:") {
                    Button("Mở trong Finder") { NSWorkspace.shared.open(bottle.driveC) }
                }
                ForEach([WineTool.winecfg, .control, .uninstaller, .regedit, .taskmgr, .cmd], id: \.self) { tool in
                    LabeledContent(tool.displayName) {
                        Button("Mở") {
                            do { try model.manager.wine(for: bottle).openTool(tool) }
                            catch { model.show(.error, error.localizedDescription) }
                        }
                    }
                }
            }

            Section {
                LabeledContent("Chương trình bị treo?") {
                    Button("Tắt mọi chương trình") { model.kill(bottle) }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
    }

    /// Binding đổi cấu hình rồi áp vào registry Wine ở nền.
    private func binding<T: Sendable>(_ key: WritableKeyPath<BottleConfig, T>,
                                      apply: @escaping @Sendable (Wine, T) throws -> Void) -> Binding<T> {
        Binding(
            get: { bottle.config[keyPath: key] },
            set: { value in
                Task { await model.update(bottle, apply: { try apply($0, value) }) { $0[keyPath: key] = value } }
            })
    }
}
