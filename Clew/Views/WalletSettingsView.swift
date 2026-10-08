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
                        Button("Show recovery words…") {
                            Task { seedWords = try? await model.revealSeedWords() }
                        }
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
        .confirmationDialog("Delete “\(model.activeWallet?.name ?? "wallet")”?", isPresented: $confirmingDelete) {
            Button("Delete wallet", role: .destructive) {
                Task { if await model.deleteActiveWallet() { dismiss() } }
            }
        } message: {
            Text("The XTM in it can only be recovered with its 24 recovery words. Make sure you have them.")
        }
    }

    private func commitName() {
        if let id = model.activeID { model.rename(id, to: name) }
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
