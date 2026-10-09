import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?
    @State private var showingWallets = false
    @State private var askingNewest = false
    @State private var askingEarlier = false
    @State private var earlierPasswordWallet: WalletProfile?
    @State private var asset = Asset.xtm

    enum Asset: String, CaseIterable, Identifiable {
        case xtm = "XTM", tari = "TARI"
        var id: Self { self }
    }

    private var showingTari: Bool { asset == .tari && model.showsTariSide }

    enum Sheet: Identifiable {
        case send, receive, settings, add(AddWalletSheet.Mode), detail(WalletTransaction), tariSend, tariReceive, moveToTari
        var id: String {
            if case .detail(let tx) = self { return "detail-\(tx.id)" }
            return String(describing: self)
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            content
            if showingWallets {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { showingWallets = false }
                    .transition(.opacity)
                WalletSidebar(close: { showingWallets = false }, add: { sheet = .add($0) })
                    .frame(width: 270)
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.smooth(duration: 0.3), value: showingWallets)
        .passwordPrompt("Finish your password change",
                        message: "Your Clew password was changed, but Clew was unlocked with the previous one. Enter your newest password to bring every wallet up to date.",
                        isPresented: $askingNewest) { typed in
            Task { _ = await model.finishPasswordChange(newest: typed) }
        }
        .passwordPrompt("“\(earlierPasswordWallet?.name ?? "This wallet")” uses an earlier password",
                        message: "This wallet was left on a password from before your last change. Enter that earlier password to bring it up to date.",
                        isPresented: $askingEarlier) { typed in
            if let id = earlierPasswordWallet?.id { Task { await model.switchTo(id, previousPassword: typed) } }
        }
        // The model asks; the prompt keeps its own copy of what it's about.
        .onChange(of: model.walletNeedingPreviousPassword, initial: true) {
            guard let wallet = model.walletNeedingPreviousPassword else { return }
            earlierPasswordWallet = wallet
            model.walletNeedingPreviousPassword = nil
            askingEarlier = true
        }
        .onChange(of: model.needsNewestPassword, initial: true) {
            guard model.needsNewestPassword else { return }
            model.needsNewestPassword = false
            askingNewest = true
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if Config.isTestnet { TestnetBadge() }
            topBar
            if showingTari {
                TariSide(open: { sheet = $0 })
            } else {
                xtmSide
            }
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .send: SendView()
                case .receive: ReceiveView()
                case .settings: WalletSettingsView()
                case .add(let mode): AddWalletSheet(mode: mode)
                case .detail(let tx): TransactionDetailView(tx: tx)
                case .tariSend: TariSendView()
                case .tariReceive: TariReceiveView()
                case .moveToTari: MoveToTariView()
                }
            }
            .presentationBackground(Theme.background)
        }
    }

    @ViewBuilder private var xtmSide: some View {
        // Switching wallets slides the old card out and the new one in.
        ZStack {
            BalanceCard()
                .id(model.activeID)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .padding(.horizontal, 20)
        .animation(.smooth(duration: 0.45), value: model.activeID)
        actions
            .padding(.horizontal, 20)
            .padding(.top, 14)
        if let wallet = model.activeWallet, !wallet.backedUp { backupReminder }
        history
            .padding(.top, 12)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            WalletSidebarButton { showingWallets = true }
            Spacer()
            if model.showsTariSide {
                Picker("Currency", selection: $asset) {
                    ForEach(Asset.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                .help("XTM on Tari's main chain, or TARI on Ootle, Tari's layer 2")
                Spacer()
            }
            IconButton(systemImage: model.hideBalance ? "eye.slash" : "eye",
                       help: model.hideBalance ? "Show balances" : "Hide balances") {
                model.hideBalance.toggle()
            }
            IconButton(systemImage: "gearshape", help: "Wallet settings") { sheet = .settings }
            IconButton(systemImage: "lock", help: "Lock Clew") { model.lock() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { sheet = .send } label: { Label("Send", systemImage: "arrow.up") }
                .buttonStyle(.wide)
                .disabled(model.balance.available == 0 || model.busy)
            Button { sheet = .receive } label: { Label("Receive", systemImage: "arrow.down") }
                .disabled(model.busy || model.address.isEmpty)
                .buttonStyle(.wideSecondary)
        }
    }

    private var backupReminder: some View {
        Button { sheet = .settings } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Back up this wallet's recovery words")
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(10)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    @ViewBuilder private var history: some View {
        if model.transactions.isEmpty {
            VStack(spacing: 12) {
                YarnBallView()
                    .frame(width: 84, height: 84)
                    .opacity(0.9)
                Text("Nothing here yet")
                    .font(.headline)
                Text("Click Receive to get your address and QR code.\nPayments you send and receive will show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(groupedByDay, id: \.day) { group in
                    Section {
                        ForEach(group.items) { tx in
                            TransactionRow(tx: tx)
                                .contentShape(Rectangle())
                                .onTapGesture { sheet = .detail(tx) }
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.accentColor.opacity(model.arrivals.contains(tx.id) ? 0.22 : 0))
                                        .padding(.horizontal, 6)
                                        .animation(.easeOut(duration: 1.2), value: model.arrivals))
                        }
                    } header: {
                        Text(dayTitle(group.day))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var groupedByDay: [(day: Date, items: [WalletTransaction])] {
        Dictionary(grouping: model.transactions) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

struct BalanceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Available")
                    .font(.callout.weight(.medium))
                    .opacity(0.8)
                Spacer()
                ConnectionPill(status: model.connectivity, height: model.scannedHeight, viaTor: model.useTor)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.hideBalance ? "••••••" : XTM.format(model.balance.available))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("XTM")
                    .font(.title3.weight(.semibold))
                    .opacity(0.75)
            }
            .padding(.top, 10)
            HStack(spacing: 14) {
                if model.balance.pendingIncoming > 0 {
                    detail("arrow.down.circle", "\(amount(model.balance.pendingIncoming)) incoming")
                }
                if model.balance.pendingOutgoing > 0 {
                    detail("arrow.up.circle", "\(amount(model.balance.pendingOutgoing)) outgoing")
                }
                if model.balance.timeLocked > 0 {
                    detail("clock", "\(amount(model.balance.timeLocked)) locked")
                }
            }
            .padding(.top, 8)
            .frame(minHeight: 18)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            CardBackground(top: Theme.cardTop, bottom: Theme.cardBottom)
                .shadow(color: Color.accentColor.opacity(pulse ? 0.7 : 0.3), radius: pulse ? 24 : 12, y: 6)
        }
        .scaleEffect(pulse ? 1.025 : 1)
        .animation(.default, value: model.balance)
        .onChange(of: model.arrivalCount) {
            withAnimation(.spring(duration: 0.45, bounce: 0.4)) { pulse = true }
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.easeOut(duration: 0.8)) { pulse = false }
            }
        }
    }

    @State private var pulse = false

    private func amount(_ micro: MicroTari) -> String { model.hideBalance ? "•••" : XTM.format(micro) }

    private func detail(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .opacity(0.85)
    }
}

/// The gradient, yarn pattern and sheen behind a balance card.
struct CardBackground: View {
    let top: Color
    let bottom: Color

    var body: some View {
        ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            YarnPattern()
            LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .center)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct ConnectionPill: View {
    let status: Connectivity
    let height: UInt64
    var viaTor = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
            if viaTor {
                Image(systemName: "network.badge.shield.half.filled")
                    .help("Connected through Tor")
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.15), in: Capsule())
        .help(height > 0 ? "Scanned to block \(height)" : "")
    }

    private var color: Color {
        switch status {
        case .online: .green
        case .degraded, .connecting: .yellow
        case .offline: .red
        }
    }

    private var label: String {
        switch status {
        case .online: "Synced"
        case .degraded: "Slow"
        case .connecting: "Connecting"
        case .offline: "Offline"
        }
    }
}

struct TransactionRow: View {
    @Environment(AppModel.self) private var model
    let tx: WalletTransaction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tx.isOutbound ? "arrow.up.right" : "arrow.down.left")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(iconColor.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.isOutbound ? "Sent" : "Received").font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.hideBalance ? "•••" : "\(tx.isOutbound ? "−" : "+")\(XTM.format(tx.amount))")
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                    .strikethrough(failed)
                    .foregroundStyle(tx.isOutbound || failed ? Color.primary : .green)
                StatusLabel(status: tx.status)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
        .contextMenu {
            if let address = tx.counterparty {
                Button("Copy address") { Pasteboard.copy(address) }
            }
            Button("Copy transaction ID") { Pasteboard.copy(String(tx.id)) }
        }
    }

    /// The money never moved.
    private var failed: Bool { tx.status == .cancelled || tx.status == .rejected }

    private var iconColor: Color {
        failed ? .secondary : tx.isOutbound ? .accentColor : .green
    }

    private var subtitle: String {
        let time = tx.date.formatted(date: .omitted, time: .shortened)
        return tx.note.isEmpty ? time : "\(time) · \(tx.note)"
    }
}

private struct StatusLabel: View {
    let status: WalletTransaction.Status

    var body: some View {
        switch status {
        case .confirmed:
            EmptyView()
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        case .rejected:
            Text("Rejected").font(.caption).foregroundStyle(.red)
        case .locked:
            Label("Locked", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Confirmed, but these funds can't be spent until a later block.")
        case .pending, .broadcast, .confirming:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(status == .confirming ? "Confirming" : "Pending")
            }
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }
}
