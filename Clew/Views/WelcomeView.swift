import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var restoring = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppIconView(size: 112)
            Text("Clew")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .padding(.top, 12)
            Text("A private wallet for Tari")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 14) {
                Feature(icon: "touchid", text: "Locked with Touch ID")
                Feature(icon: "desktopcomputer", text: "Keys never leave this Mac")
                Feature(icon: "eye.slash", text: "No accounts, no tracking")
            }
            .padding(.top, 36)

            Spacer()
            VStack(spacing: 10) {
                Button("Create a new wallet") {
                    Task { await model.createWallet(name: model.suggestedWalletName) }
                }
                .buttonStyle(.wide)
                Button("I already have recovery words") { restoring = true }
                    .buttonStyle(.wideSecondary)
            }
            .disabled(model.busy)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .overlay { if model.busy { ProgressView() } }
        .sheet(isPresented: $restoring) {
            AddWalletSheet(mode: .restore).presentationBackground(Theme.background)
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
    enum Mode { case create, restore }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var name = ""
    @State private var words = ""

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

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(mode == .create ? "Create" : "Restore") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || (mode == .restore && wordCount != 24))
            }
        }
        .padding(24)
        .frame(width: 420)
        .overlay { if model.busy { ProgressView() } }
        .onAppear { name = model.suggestedWalletName }
        .onDisappear { words = "" }
    }

    private func submit() async {
        switch mode {
        case .create:
            dismiss()
            await model.createWallet(name: name)
        case .restore:
            if await model.restoreWallet(name: name, from: words) { dismiss() }
        }
    }
}
