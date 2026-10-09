import SwiftUI

struct BackupView: View {
    @Environment(AppModel.self) private var model
    let words: [String]
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.activeWallet?.name ?? "New wallet")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
                Text("Write down your recovery words")
                    .font(.title2.weight(.semibold))
            }
            .padding(.top, 20)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                Text("These 24 words are the only way to recover this wallet. Write them on paper, in order. Never type them into a website or share them.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            SeedGrid(words: words)

            Spacer()
            Toggle("I've written down all 24 words", isOn: $confirmed)
                .toggleStyle(.checkbox)
            Button("Continue") { model.finishBackup() }
                .buttonStyle(.wide)
                .disabled(!confirmed)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

struct LockedView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppIconView(size: 96)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor, in: Circle())
                        .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                        .offset(x: 4, y: 4)
                }
            if model.needsPasswordSwitch { switchToPassword } else { unlock }
            Spacer()
            NetworkSwitchButton()
        }
        .padding(.horizontal, 40)
        .overlay { if model.busy { ProgressView().offset(y: 160) } }
        .onChange(of: model.phase) { password = ""; confirmation = "" }
    }

    private var unlock: some View {
        VStack(spacing: 0) {
            Text("\(NetworkSwitch.appName) is locked")
                .font(.title2.weight(.semibold))
                .padding(.top, 20)
            Text(model.wallets.count == 1 ? "1 wallet" : "\(model.wallets.count) wallets")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .padding(.top, 24)
                .onSubmit(submit)
            Button("Unlock", action: submit)
                .buttonStyle(.wide)
                .keyboardShortcut(.defaultAction)
                .frame(width: 240)
                .padding(.top, 10)
                .disabled(model.busy)
            if model.touchIDEnabled {
                Button { Task { await model.unlock(password: nil) } } label: {
                    Label("Use Touch ID", systemImage: "touchid")
                }
                .buttonStyle(.borderless)
                .padding(.top, 12)
                .disabled(model.busy)
            }
        }
    }

    private func submit() {
        let typed = password
        password = ""
        Task { await model.unlock(password: typed) }
    }

    /// Shown once, for wallets made before passwords: choose a password, confirm with Touch ID or
    /// the Mac password one last time, and every wallet is re-encrypted with it.
    private var switchToPassword: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a password")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            Text("Clew now uses a password instead of the Keychain. Pick one, and your wallets will be switched over. macOS will ask for Touch ID or your Mac password one last time.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            NewPasswordFields(password: $password, confirmation: $confirmation)
            Button("Switch to password") {
                let chosen = password
                Task { await model.switchToPassword(chosen) }
            }
            .buttonStyle(.wide)
            .disabled(model.busy || !NewPasswordFields.isValid(password, confirmation))
        }
        .frame(width: 320)
    }
}
