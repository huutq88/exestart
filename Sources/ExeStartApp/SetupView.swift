import ExeStartKit
import SwiftUI

/// Màn hình lần đầu: tải và cài Wine.
struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Chạy ứng dụng Windows trên Mac")
                    .font(.title.bold())
                Text("ExeStart dùng Wine để chạy file .exe trực tiếp, không cần máy ảo hay bản quyền Windows. Cần tải Wine một lần.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
            }

            content
                .frame(maxWidth: 420)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { if model.latestStable == nil { await model.fetchLatestStable() } }
    }

    @ViewBuilder private var content: some View {
        switch model.installState {
        case .idle:
            VStack(spacing: 12) {
                Button {
                    Task { await model.installRuntime() }
                } label: {
                    Text("Tải và cài Wine").frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.latestStable == nil)

                if let r = model.latestStable {
                    Text("Wine \(r.channel.capitalized) \(r.version) · \(r.sizeText) · từ GitHub (Gcenx/macOS_Wine_builds)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if model.loadingRemote {
                    ProgressView("Đang kiểm tra bản mới nhất…").controlSize(.small)
                }
            }

        case let .working(label, progress):
            VStack(alignment: .leading, spacing: 8) {
                if let progress {
                    ProgressView(value: progress) {
                        Text(label)
                    } currentValueLabel: {
                        Text("\(Int(progress * 100))%").monospacedDigit()
                    }
                } else {
                    ProgressView { Text(label) }.progressViewStyle(.linear)
                }
                Text("Có thể dùng máy bình thường trong lúc chờ. Đừng đóng app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case let .failed(message):
            VStack(spacing: 12) {
                Label("Chưa cài được Wine", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Thử lại") { Task { await model.installRuntime() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct NewBottleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var windows: WindowsVersion = .win10

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameError: String? {
        if trimmed.isEmpty { return nil }
        if model.bottles.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "Đã có bottle tên này."
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        if !trimmed.unicodeScalars.allSatisfy(allowed.contains) || trimmed.hasPrefix(".") {
            return "Chỉ dùng chữ, số, dấu cách, “-”, “_” và “.”."
        }
        return nil
    }
    private var creating: Bool { model.busy.contains(trimmed) }

    var body: some View {
        Form {
            Section {
                TextField("Tên bottle", text: $name, prompt: Text("vd. Văn phòng"))
                if let nameError {
                    Text(nameError).font(.callout).foregroundStyle(.red)
                }
                Picker("Phiên bản Windows", selection: $windows) {
                    ForEach(WindowsVersion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("Mỗi bottle là một ổ C: riêng. Tạo lần đầu mất khoảng 30–60 giây.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Huỷ") { dismiss() }.disabled(creating)
            }
            ToolbarItem(placement: .confirmationAction) {
                if creating {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Tạo bottle") {
                        Task {
                            if await model.createBottle(name: trimmed, windows: windows) { dismiss() }
                        }
                    }
                    .disabled(trimmed.isEmpty || nameError != nil)
                }
            }
        }
        .interactiveDismissDisabled(creating)
    }
}

/// Mở .exe từ Finder khi có nhiều bottle: hỏi chạy ở bottle nào.
struct ChooseBottleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let file: URL
    @State private var choice: Bottle.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chạy “\(file.lastPathComponent)” trong bottle nào?")
                .font(.headline)
            if model.bottles.isEmpty {
                Text("Chưa có bottle. Hãy tạo một bottle trước.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Bottle", selection: $choice) {
                    ForEach(model.bottles) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Chạy") {
                    if let b = model.bottles.first(where: { $0.id == choice }) { model.run(file, in: b) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { choice = model.selection ?? model.bottles.first?.id }
    }
}
