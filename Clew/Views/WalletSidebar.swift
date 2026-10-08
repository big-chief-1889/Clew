import SwiftUI

/// Wallet name in the top bar. Opens the wallet sidebar.
struct WalletSidebarButton: View {
    @Environment(AppModel.self) private var model
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(model.activeWallet?.name ?? "Wallet")
                    .font(.headline)
                    .lineLimit(1)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Your wallets")
        .disabled(model.busy)
    }
}

/// Panel that slides in from the left listing every wallet, with New and Restore at the bottom.
struct WalletSidebar: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    let add: (AddWalletSheet.Mode) -> Void
    /// The wallet being deleted. Kept separately from the dialogs, which clear their own flags.
    @State private var deleting: WalletProfile?
    @State private var confirming = false
    @State private var askingPassword = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Wallets").font(.title3.weight(.semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.wallets) { wallet in
                        row(wallet)
                    }
                }
                .padding(.horizontal, 10)
            }

            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 2) {
                action("New wallet", icon: "plus") { add(.create) }
                action("Restore wallet", icon: "arrow.counterclockwise") { add(.restore) }
            }
            .padding(10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
        }
        .onExitCommand(perform: close)
        .confirmationDialog("Delete “\(deleting?.name ?? "wallet")”?", isPresented: $confirming) {
            Button("Delete wallet", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The XTM in it can only be recovered with its 24 recovery words. Make sure you have them.")
        }
        .passwordPrompt("Delete “\(deleting?.name ?? "wallet")”", isPresented: $askingPassword) { typed in
            Task { await delete(password: typed) }
        }
        .alert("Couldn't delete", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private func delete(password: String? = nil) async {
        guard let wallet = deleting else { return }
        do {
            _ = try await model.deleteWallet(wallet.id, password: password)
        } catch is AppModel.PasswordNeeded {
            askingPassword = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func row(_ wallet: WalletProfile) -> some View {
        let active = wallet.id == model.activeID
        return Button {
            close()
            Task { await model.switchTo(wallet.id) }
        } label: {
            HStack(spacing: 10) {
                Text(String(wallet.name.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(active ? Color.white : .secondary)
                    .frame(width: 28, height: 28)
                    .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                in: Circle())
                Text(wallet.name)
                    .fontWeight(active ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(active ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .contextMenu {
            Button("Delete “\(wallet.name)”…", role: .destructive) {
                deleting = wallet
                confirming = true
            }
        }
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button {
            close()
            perform()
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}
