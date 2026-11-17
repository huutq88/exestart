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
                            Label("Chưa có bottle", systemImage: "shippingbox")
                        } description: {
                            Text("Bottle là một ổ C: Windows riêng. Mỗi nhóm chương trình nên có một bottle.")
                        } actions: {
                            Button("Tạo bottle") { showNewBottle = true }
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
            "Chuyển bottle “\(confirmDelete?.name ?? "")” vào Thùng rác?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { bottle in
            Button("Chuyển vào Thùng rác", role: .destructive) { model.delete(bottle) }
        } message: { _ in
            Text("Mọi chương trình và dữ liệu đã cài trong bottle này sẽ bị chuyển đi. Bạn có thể khôi phục từ Thùng rác.")
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
            Section("Bottle") {
                ForEach(model.bottles) { bottle in
                    HStack {
                        Label(bottle.name, systemImage: "shippingbox")
                        Spacer()
                        if model.busy.contains(bottle.name) { ProgressView().controlSize(.small) }
                    }
                    .tag(bottle.id)
                    .contextMenu {
                        Button("Mở ổ C: trong Finder") { NSWorkspace.shared.open(bottle.driveC) }
                        Button("Tắt mọi chương trình") { model.kill(bottle) }
                        Divider()
                        Button("Chuyển vào Thùng rác…", role: .destructive) { confirmDelete = bottle }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        .safeAreaInset(edge: .bottom) {
            Button { showNewBottle = true } label: {
                Label("Bottle mới", systemImage: "plus")
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

/// Thanh thông báo kết quả ở đáy cửa sổ — có link mở log, tự ẩn sau 8 giây.
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
                    Button("Xem log") { NSWorkspace.shared.open(log) }
                }
                Button { model.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Đóng thông báo")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
            .accessibilityElement(children: .combine)
            .task(id: notice.id) {
                // Lỗi giữ lại cho đến khi người dùng đóng.
                guard notice.kind == .success else { return }
                try? await Task.sleep(for: .seconds(8))
                if model.notice?.id == notice.id { model.notice = nil }
            }
        }
    }
}
