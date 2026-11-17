import ExeStartKit
import SwiftUI

struct BottleDetailView: View {
    enum Tab: String, CaseIterable { case programs = "Programs", library = "Libraries", settings = "Settings" }

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
        .navigationSubtitle(model.busy.contains(bottle.name) ? "Applying changes…" : bottle.config.windowsVersion.displayName)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.chooseFile(for: bottle) } label: {
                    Label("Run .exe File…", systemImage: "play.fill")
                }
                .help("Choose a .exe, .msi, .bat or .lnk file to run in this bottle (⌘O)")
            }
        }
    }
}

// MARK: - Programs

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
                ProgressView("Looking for programs…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if programs.isEmpty {
                ContentUnavailableView {
                    Label("No Programs Installed", systemImage: "square.and.arrow.down")
                } description: {
                    Text("Run an installer (.exe or .msi), or drag a file into this window. Installed programs will appear here.")
                } actions: {
                    Button("Run Installer…") { model.chooseFile(for: bottle) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    if filtered.isEmpty {
                        Text("No programs match “\(query)”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { program in
                        ProgramRow(program: program, bottle: bottle,
                                   pinned: bottle.config.pinned.contains(program.url.path))
                    }
                }
                .searchable(text: $query, placement: .toolbar, prompt: "Search Programs")
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
                            .accessibilityLabel("Pinned")
                    }
                }
                Text(windowsPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Open") { model.run(program.url, in: bottle) }
                .accessibilityLabel("Open \(program.name)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.run(program.url, in: bottle) }
        .contextMenu {
            Button("Open") { model.run(program.url, in: bottle) }
            Button("Add to Launchpad") { model.createShortcut(program, in: bottle) }
            Button(pinned ? "Unpin" : "Pin to Top") { model.togglePin(program, in: bottle) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([program.url]) }
        }
    }

    /// Shows a Windows-style path (C:\...), which is more familiar to users.
    private var windowsPath: String {
        let c = bottle.driveC.path
        guard program.url.path.hasPrefix(c) else { return program.url.path }
        return "C:" + program.url.path.dropFirst(c.count).replacingOccurrences(of: "/", with: "\\")
    }
}

// MARK: - Libraries (winetricks)

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle
    @State private var running: String?
    @State private var log = ""
    @State private var lastResult: (verb: String, ok: Bool)?
    @State private var missingTools = Winetricks.missingTools
    @State private var installingTools = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                if !missingTools.isEmpty { missingToolsBanner }
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
                                Text("Installing…").foregroundStyle(.secondary)
                            } else {
                                if let r = lastResult, r.verb == item.verb {
                                    Label(r.ok ? "Installed" : "Failed", systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                        .foregroundStyle(r.ok ? .green : .red)
                                }
                                Button("Install") { install(item.verb) }
                                    .disabled(running != nil || installingTools)
                            }
                        }
                    }
                } header: {
                    Text("Common Windows Libraries")
                } footer: {
                    Text("Install these when a program reports a missing DLL, shows broken fonts, or needs .NET or Visual C++. Each package takes from a few seconds to a few minutes.")
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
                .accessibilityLabel("Installation Log")
            }
        }
    }

    /// Warns that cabextract is missing, with a button to install it via Homebrew (or a link to install Homebrew if it isn’t present).
    private var missingToolsBanner: some View {
        let names = missingTools.joined(separator: ", ")
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(names) is missing — many packages will fail to install.")
                Text(Homebrew.isInstalled
                     ? "ExeStart can install \(names) with Homebrew (takes a few seconds)."
                     : "Homebrew is required to install \(names). After installing Homebrew, reopen this tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if installingTools {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            } else if Homebrew.isInstalled {
                Button("Install \(names)") { installTools() }
                    .disabled(running != nil)
            } else {
                Link("Open brew.sh", destination: URL(string: Homebrew.website)!)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func installTools() {
        guard !installingTools, running == nil else { return }
        installingTools = true
        log = ""
        Task {
            do {
                let ok = try await Homebrew.installWinetricksTools { chunk in
                    Task { @MainActor in log += chunk }
                }
                missingTools = Winetricks.missingTools
                model.show(ok ? .success : .error,
                           ok ? "Installed cabextract. You can now install the packages below."
                              : "Homebrew finished, but cabextract still wasn’t found. See the log below.")
            } catch {
                model.show(.error, "Couldn’t install cabextract: \(error.localizedDescription). You can run it yourself in Terminal: brew install cabextract")
            }
            installingTools = false
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
                           code == 0 ? "Installed \(verb) in “\(bottle.name)”."
                                     : "Installing \(verb) failed (code \(code)). See the log below.")
            } catch {
                lastResult = (verb, false)
                model.show(.error, "Couldn’t run winetricks: \(error.localizedDescription)")
            }
            running = nil
        }
    }
}

// MARK: - Settings

struct BottleSettingsView: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle

    private var busy: Bool { model.busy.contains(bottle.name) }

    var body: some View {
        Form {
            Section("Windows") {
                Picker("Windows Version", selection: binding(\.windowsVersion) { wine, v in
                    try wine.setWindowsVersion(v)
                }) {
                    ForEach(WindowsVersion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Wine Runtime", selection: Binding(
                    get: { bottle.config.runtimeID ?? "" },
                    set: { id in
                        Task { await model.update(bottle, apply: { _ in }) { $0.runtimeID = id.isEmpty ? nil : id } }
                    })) {
                    Text("Default").tag("")
                    ForEach(model.runtimes) { Text($0.displayName).tag($0.id) }
                }
            }

            Section {
                Toggle("Retina Mode", isOn: binding(\.retinaMode) { wine, on in try wine.setRetinaMode(on) })
                Picker("Text & Interface Size", selection: binding(\.dpi) { wine, dpi in try wine.setDPI(dpi) }) {
                    Text("100% (96 DPI)").tag(96)
                    Text("125% (120 DPI)").tag(120)
                    Text("150% (144 DPI)").tag(144)
                    Text("200% (192 DPI)").tag(192)
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Retina mode makes text sharper but windows smaller — raise the scale to 150–200% to compensate. Quit and reopen the program to see the change.")
                    .foregroundStyle(.secondary)
            }

            Section("Windows Tools") {
                LabeledContent("C: Drive") {
                    Button("Show in Finder") { NSWorkspace.shared.open(bottle.driveC) }
                }
                ForEach([WineTool.winecfg, .control, .uninstaller, .regedit, .taskmgr, .cmd], id: \.self) { tool in
                    LabeledContent(tool.displayName) {
                        Button("Open") {
                            do { try model.manager.wine(for: bottle).openTool(tool) }
                            catch { model.show(.error, error.localizedDescription) }
                        }
                    }
                }
            }

            Section {
                LabeledContent("Program not responding?") {
                    Button("Force Quit All Programs") { model.kill(bottle) }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
    }

    /// Binding that updates the configuration and applies it to the Wine registry in the background.
    private func binding<T: Sendable>(_ key: WritableKeyPath<BottleConfig, T>,
                                      apply: @escaping @Sendable (Wine, T) throws -> Void) -> Binding<T> {
        Binding(
            get: { bottle.config[keyPath: key] },
            set: { value in
                Task { await model.update(bottle, apply: { try apply($0, value) }) { $0[keyPath: key] = value } }
            })
    }
}
