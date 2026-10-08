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
            Text("Clew is locked")
                .font(.title2.weight(.semibold))
                .padding(.top, 20)
            Text(model.wallets.count == 1 ? "1 wallet" : "\(model.wallets.count) wallets")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Button { Task { await model.unlock() } } label: {
                Label("Unlock", systemImage: "touchid")
            }
            .buttonStyle(.wide)
            .keyboardShortcut(.defaultAction)
            .frame(width: 200)
            .padding(.top, 28)
            .disabled(model.busy)
            Spacer()
        }
        .overlay { if model.busy { ProgressView().offset(y: 120) } }
    }
}
