import SwiftUI

/// Settings for the open wallet, shown as a sheet over the main window.
struct WalletSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var nodeText = ""
    @State private var seedWords: [String]?
    @State private var repairStarted = false
    @State private var confirmingDelete = false
    /// Which action is waiting for the password to be typed. Kept separately from the prompt's flag.
    @State private var passwordFor: Guarded?
    @State private var askingPassword = false
    @State private var showingPasswordChange = false
    @State private var error: String?

    private enum Guarded { case reveal, delete }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Wallet settings").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { commitName(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .labelsHidden()
                        .onSubmit(commitName)
                }

                Section {
                    if let seedWords {
                        SeedGrid(words: seedWords)
                            .padding(.vertical, 4)
                        Button("I've written them down — hide") {
                            model.markBackedUp()
                            self.seedWords = nil
                        }
                    } else {
                        Button("Show recovery words…") { Task { await reveal() } }
                    }
                } header: {
                    Text("Recovery words")
                } footer: {
                    if model.activeWallet?.backedUp == false {
                        Label("Not backed up yet", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button("Change password…") { showingPasswordChange = true }
                        .disabled(model.busy)
                    if TouchIDShortcut.isAvailable {
                        Toggle("Unlock with Touch ID", isOn: .init(
                            get: { model.touchIDEnabled },
                            set: { model.setTouchID($0) }))
                    }
                } header: {
                    Text("Password (all wallets)")
                } footer: {
                    Text("Touch ID is a shortcut: your password still protects the wallet files, and always works.")
                }

                Section {
                    Toggle("Connect through Tor", isOn: .init(
                        get: { model.useTor },
                        set: { model.setUseTor($0) }))
                    if model.useTor { TorStatusRow() }
                } header: {
                    Text("Privacy (all wallets)")
                } footer: {
                    Text("Tor hides your IP address from the node and from your internet provider. Connecting takes a little longer. If Tor isn't working, Clew stays offline instead of connecting directly.")
                }

                Section {
                    TextField("Node URL", text: $nodeText)
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                    if !nodeText.isEmpty && !AppModel.isAcceptableNodeURL(nodeText) {
                        Text("Use an https:// address (plain http only works for this Mac or a .onion address).")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Use default") { nodeText = Config.defaultNodeURL }
                            .disabled(nodeText == Config.defaultNodeURL)
                        Spacer()
                        Button("Save & reconnect") {
                            Task { await model.setNodeURL(nodeText) }
                        }
                        .disabled(nodeText == model.nodeURL || !AppModel.isAcceptableNodeURL(nodeText) || model.busy)
                    }
                } header: {
                    Text("Tari node (all wallets)")
                } footer: {
                    Text(model.useTor
                         ? "The node sees the transactions you send, but not your IP address. Your keys are never sent to it."
                         : "The node sees your IP address and the transactions you send. Your keys are never sent to it.")
                }

                Section {
                    HStack {
                        Button("Repair wallet") {
                            repairStarted = true
                            Task { await model.repairWallet() }
                        }
                        .disabled(model.busy)
                        if repairStarted {
                            if model.busy {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Re-scanning in the background", systemImage: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Repair")
                } footer: {
                    Text("If your balance or history ever looks wrong: re-checks everything with the node and re-reads the blockchain. Nothing is deleted. It can take a few minutes, longer over Tor.")
                }

                Section {
                    Button("Delete “\(model.activeWallet?.name ?? "wallet")” from this Mac…", role: .destructive) {
                        confirmingDelete = true
                    }
                    .disabled(model.busy)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 440, height: seedWords == nil ? 600 : 720)
        .onAppear {
            name = model.activeWallet?.name ?? ""
            nodeText = model.nodeURL
        }
        .onDisappear { seedWords = nil }
        .onChange(of: model.phase) { dismiss() }
        .passwordPrompt(passwordFor == .delete ? "Delete wallet" : "Show recovery words",
                        isPresented: $askingPassword) { typed in
            let action = passwordFor
            Task { action == .delete ? await delete(password: typed) : await reveal(password: typed) }
        }
        .sheet(isPresented: $showingPasswordChange) {
            ChangePasswordView().presentationBackground(Theme.background)
        }
        .alert("Something went wrong", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
        .confirmationDialog("Delete “\(model.activeWallet?.name ?? "wallet")”?", isPresented: $confirmingDelete) {
            Button("Delete wallet", role: .destructive) {
                Task { await delete() }
            }
        } message: {
            Text("The XTM in it can only be recovered with its 24 recovery words. Make sure you have them.")
        }
    }

    private func commitName() {
        if let id = model.activeID { model.rename(id, to: name) }
    }

    private func reveal(password: String? = nil) async {
        do {
            seedWords = try await model.revealSeedWords(password: password)
        } catch is AppModel.PasswordNeeded {
            passwordFor = .reveal
            askingPassword = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(password: String? = nil) async {
        do {
            guard let id = model.activeID else { return }
            if try await model.deleteWallet(id, password: password) { dismiss() }
        } catch is AppModel.PasswordNeeded {
            passwordFor = .delete
            askingPassword = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Current password, then the new one twice.
private struct ChangePasswordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change password").font(.title3.weight(.semibold))
            SecureField("Current password", text: $current)
                .textFieldStyle(.roundedBorder)
            Text("New password").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            NewPasswordFields(password: $new, confirmation: $confirmation)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Change") {
                    Task { if await model.changePassword(current: current, new: new) { dismiss() } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || !NewPasswordFields.isValid(new, confirmation))
            }
        }
        .padding(24)
        .frame(width: 380)
        .overlay { if model.busy { ProgressView() } }
        .onDisappear { current = ""; new = ""; confirmation = "" }
    }
}

private struct TorStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            switch model.tor.state {
            case .off:
                Text("Off").foregroundStyle(.secondary)
            case .starting:
                ProgressView().controlSize(.small)
                Text("Connecting to Tor…").foregroundStyle(.secondary)
            case .ready:
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                Text("Connected through Tor")
            case .failed(let reason):
                Image(systemName: "xmark.shield.fill").foregroundStyle(.red)
                Text(reason).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Retry") { Task { await model.retryTor() } }
            }
        }
        .font(.callout)
    }
}
