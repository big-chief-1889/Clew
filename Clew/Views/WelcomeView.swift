import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var adding: AddWalletSheet.Mode?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppIconView(size: 112)
            Text(NetworkSwitch.appName)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .padding(.top, 12)
            Text("A private wallet for Tari")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 14) {
                Feature(icon: "lock", text: "Locked with your password")
                Feature(icon: "desktopcomputer", text: "Keys never leave this Mac")
                Feature(icon: "eye.slash", text: "No accounts, no tracking")
            }
            .padding(.top, 36)

            Spacer()
            VStack(spacing: 10) {
                Button("Create a new wallet") { adding = .create }
                    .buttonStyle(.wide)
                Button("I already have recovery words") { adding = .restore }
                    .buttonStyle(.wideSecondary)
            }
            .disabled(model.busy)
            NetworkSwitchButton()
                .padding(.top, 14)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .overlay { if model.busy { ProgressView() } }
        .sheet(item: $adding) { mode in
            AddWalletSheet(mode: mode).presentationBackground(Theme.background)
        }
    }
}

private struct Feature: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(text)
        }
    }
}

/// Creates or restores a wallet with a name. Used from the welcome screen and the wallet menu.
struct AddWalletSheet: View {
    enum Mode: String, Identifiable {
        case create, restore
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var name = ""
    @State private var words = ""
    @State private var password = ""
    @State private var confirmation = ""
    /// The first wallet chooses the password; later ones use it.
    @State private var choosingPassword = false

    private var wordCount: Int { SeedWords.parse(words).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode == .create ? "New wallet" : "Restore a wallet")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                TextField(model.suggestedWalletName, text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if mode == .restore {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recovery words").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextEditor(text: $words)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        .frame(height: 130)
                        .privateWindow()
                    HStack {
                        Text("Enter all 24 words in order, separated by spaces.")
                        Spacer()
                        Text("\(wordCount)/24")
                            .monospacedDigit()
                            .foregroundStyle(wordCount == 24 ? .green : .secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("You'll see 24 recovery words next. Write them down — they're the only backup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if choosingPassword {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Password").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    NewPasswordFields(password: $password, confirmation: $confirmation)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(mode == .create ? "Create" : "Restore") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || (mode == .restore && wordCount != 24)
                              || (choosingPassword && !NewPasswordFields.isValid(password, confirmation)))
            }
        }
        .padding(24)
        .frame(width: 420)
        .overlay { if model.busy { ProgressView() } }
        .onAppear {
            name = model.suggestedWalletName
            choosingPassword = model.needsNewPassword
        }
        .onDisappear { words = ""; password = ""; confirmation = "" }
    }

    private func submit() async {
        switch mode {
        case .create:
            let chosen = choosingPassword ? password : nil
            dismiss()
            await model.createWallet(name: name, password: chosen)
        case .restore:
            if await model.restoreWallet(name: name, from: words, password: choosingPassword ? password : nil) {
                dismiss()
            }
        }
    }
}
