import ExeStartKit
import SwiftUI

/// First-run screen: download and install Wine.
struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Run Windows Apps on Your Mac")
                    .font(.title.bold())
                Text("ExeStart uses Wine to run .exe files directly — no virtual machine or Windows license needed. Wine only needs to be downloaded once.")
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
                    Text("Download and Install Wine").frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.latestStable == nil)

                if let r = model.latestStable {
                    Text("Wine \(r.channel.capitalized) \(r.version) · \(r.sizeText) · from GitHub (Gcenx/macOS_Wine_builds)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if model.loadingRemote {
                    ProgressView("Checking for the latest version…").controlSize(.small)
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
                Text("You can keep using your Mac while you wait. Don’t quit the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case let .failed(message):
            VStack(spacing: 12) {
                Label("Couldn’t Install Wine", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try Again") { Task { await model.installRuntime() } }
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
            return "A bottle with this name already exists."
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        if !trimmed.unicodeScalars.allSatisfy(allowed.contains) || trimmed.hasPrefix(".") {
            return "Use only letters, numbers, spaces, “-”, “_” and “.”."
        }
        return nil
    }
    private var creating: Bool { model.busy.contains(trimmed) }

    var body: some View {
        Form {
            Section {
                TextField("Bottle Name", text: $name, prompt: Text("e.g. Office"))
                if let nameError {
                    Text(nameError).font(.callout).foregroundStyle(.red)
                }
                Picker("Windows Version", selection: $windows) {
                    ForEach(WindowsVersion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("Each bottle is a separate C: drive. Creating one takes about 30–60 seconds.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(creating)
            }
            ToolbarItem(placement: .confirmationAction) {
                if creating {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Create Bottle") {
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

/// Opening a .exe from Finder with several bottles: ask which bottle to run it in.
struct ChooseBottleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let file: URL
    @State private var choice: Bottle.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which bottle should run “\(file.lastPathComponent)”?")
                .font(.headline)
            if model.bottles.isEmpty {
                Text("There are no bottles yet. Create a bottle first.")
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
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run") {
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
