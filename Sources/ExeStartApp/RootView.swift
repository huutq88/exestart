import ExeStartKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showNewBottle = false
    @State private var confirmDelete: Bottle?

    var body: some View {
        Group {
            if model.runtimes.isEmpty {
                SetupView()
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    if let bottle = model.selectedBottle {
                        BottleDetailView(bottle: bottle)
                            .id(bottle.id)
                    } else {
                        ContentUnavailableView {
                            Label("No Bottles", systemImage: "shippingbox")
                        } description: {
                            Text("A bottle is a separate Windows C: drive. Use one bottle for each group of programs.")
                        } actions: {
                            Button("Create Bottle") { showNewBottle = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { NoticeBar() }
        .sheet(isPresented: $showNewBottle) { NewBottleSheet() }
        .sheet(item: Binding(get: { model.pendingFile.map(PendingFile.init) },
                             set: { model.pendingFile = $0?.url })) { pending in
            ChooseBottleSheet(file: pending.url)
        }
        .confirmationDialog(
            "Move bottle “\(confirmDelete?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { bottle in
            Button("Move to Trash", role: .destructive) { model.delete(bottle) }
        } message: { _ in
            Text("All programs and data installed in this bottle will be moved to the Trash. You can restore it from the Trash.")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.open(url) } }
                }
            }
            return true
        }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section("Bottles") {
                ForEach(model.bottles) { bottle in
                    HStack {
                        Label(bottle.name, systemImage: "shippingbox")
                        Spacer()
                        if model.busy.contains(bottle.name) { ProgressView().controlSize(.small) }
                    }
                    .tag(bottle.id)
                    .contextMenu {
                        Button("Show C: Drive in Finder") { NSWorkspace.shared.open(bottle.driveC) }
                        Button("Force Quit All Programs") { model.kill(bottle) }
                        Divider()
                        Button("Move to Trash…", role: .destructive) { confirmDelete = bottle }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        .safeAreaInset(edge: .bottom) {
            Button { showNewBottle = true } label: {
                Label("New Bottle", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
    }
}

private struct PendingFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Result banner at the bottom of the window — links to the log and hides itself after 8 seconds.
struct NoticeBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let notice = model.notice {
            HStack(spacing: 12) {
                Image(systemName: notice.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(notice.kind == .success ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Text(notice.text)
                    .textSelection(.enabled)
                    .lineLimit(3)
                Spacer()
                if let log = notice.log {
                    Button("Show Log") { NSWorkspace.shared.open(log) }
                }
                Button { model.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss Notification")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
            .accessibilityElement(children: .combine)
            .task(id: notice.id) {
                // Errors stay until the user dismisses them.
                guard notice.kind == .success else { return }
                try? await Task.sleep(for: .seconds(8))
                if model.notice?.id == notice.id { model.notice = nil }
            }
        }
    }
}
