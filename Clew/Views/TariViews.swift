import SwiftUI

/// The TARI side of a wallet: its Ootle (Tari layer 2) balance, actions and history. Testnet only
/// for now, so the coins are tTARI and have no value.
struct TariSide: View {
    @Environment(AppModel.self) private var model
    let open: (HomeView.Sheet) -> Void
    @State private var claiming = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            TariCard()
                .padding(.horizontal, 20)
            actions
                .padding(.horizontal, 20)
                .padding(.top, 14)
            history
                .padding(.top, 12)
        }
        .alert("Something went wrong", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private var ready: Bool { model.ootleState == .ready }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { open(.tariSend) } label: { Label("Send", systemImage: "arrow.up") }
                    .buttonStyle(.wide)
                    .disabled(!ready || model.tariBalance == 0 || model.ootleBusy)
                Button { open(.tariReceive) } label: { Label("Receive", systemImage: "arrow.down") }
                    .buttonStyle(.wideSecondary)
                    .disabled(!ready || model.ootleAddress.isEmpty)
            }
            Button { open(.moveToTari) } label: { Label("Move XTM to TARI", systemImage: "arrow.right.circle") }
                .buttonStyle(.wideSecondary)
                .disabled(!ready)
            // Only offered to a wallet that has never had TARI: the faucet gives each account one claim.
            if ready && model.tariHistory.isEmpty && model.tariBalance == 0 {
                Button { Task { await claim() } } label: {
                    HStack(spacing: 6) {
                        if claiming { ProgressView().controlSize(.small) }
                        Label(claiming ? "Claiming…" : "Get 1,000 free test TARI", systemImage: "gift")
                    }
                }
                .buttonStyle(.wideSecondary)
                .disabled(claiming || model.ootleBusy)
            }
        }
    }

    private func claim() async {
        claiming = true
        defer { claiming = false }
        do {
            try await model.claimTestTari()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder private var history: some View {
        if model.tariHistory.isEmpty && model.tariMoves.isEmpty {
            VStack(spacing: 12) {
                YarnBallView()
                    .frame(width: 84, height: 84)
                    .opacity(0.9)
                Text("No TARI yet")
                    .font(.headline)
                Text("This is Ootle's testnet: TARI here is for trying things out and has no value. Payments you receive can take a while to show up, sometimes hours.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !model.tariMoves.isEmpty {
                    Section {
                        ForEach(Array(model.tariMoves.enumerated()), id: \.offset) { MoveRow(move: $0.element) }
                        if let problem = model.tariMoveProblem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("Moving to TARI")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(groupedByDay, id: \.day) { group in
                    Section {
                        ForEach(group.items) { TariRow(entry: $0) }
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

    private var groupedByDay: [(day: Date, items: [OotleEntry])] {
        Dictionary(grouping: model.tariHistory) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

/// XTM on its way to the TARI side.
private struct MoveRow: View {
    @Environment(AppModel.self) private var model
    let move: OotleMove

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: 34, height: 34)
                .background(.orange.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.hideBalance ? "•••" : XTM.format(move.amount)) XTM → TARI").font(.body.weight(.medium))
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            ProgressView().controlSize(.small)
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }

    private var status: String {
        let started = move.date.formatted(date: .abbreviated, time: .shortened)
        switch move.status {
        case .confirming: return "Confirming on Tari's main chain · started \(started)"
        case .waiting, .claimed: return "Claimed automatically about a day after \(started)"
        }
    }
}

struct TariCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Available")
                    .font(.callout.weight(.medium))
                    .opacity(0.8)
                Spacer()
                ConnectionPill(status: status, height: 0, viaTor: model.useTor)
            }
            content
                .padding(.top, 10)
            Text("Ootle testnet · no value")
                .font(.caption.weight(.medium))
                .opacity(0.85)
                .padding(.top, 8)
                .frame(minHeight: 18)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            CardBackground(top: Theme.tariCardTop, bottom: Theme.tariCardBottom)
                .shadow(color: Theme.tariCardTop.opacity(0.3), radius: 12, y: 6)
        }
        .animation(.default, value: model.tariBalance)
    }

    @ViewBuilder private var content: some View {
        switch model.ootleState {
        case .ready:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.hideBalance ? "••••••" : XTM.format(model.tariBalance))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("tTARI")
                    .font(.title3.weight(.semibold))
                    .opacity(0.75)
            }
        case .off, .opening:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Opening…")
            }
            .font(.title3.weight(.semibold))
            .frame(minHeight: 46)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't open the TARI wallet").font(.headline)
                Text(reason).font(.caption).opacity(0.85).lineLimit(3)
                Button("Try again") { model.retryOotle() }
                    .controlSize(.small)
            }
        }
    }

    private var status: Connectivity {
        switch model.ootleOnline {
        case .some(true): .online
        case .some(false): .offline
        case .none: .connecting
        }
    }
}

struct TariRow: View {
    @Environment(AppModel.self) private var model
    let entry: OotleEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isOutbound ? "arrow.up.right" : "arrow.down.left")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(entry.isOutbound ? Color.accentColor : .green)
                .frame(width: 34, height: 34)
                .background((entry.isOutbound ? Color.accentColor : .green).opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.isOutbound ? "Sent" : "Received").font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(model.hideBalance ? "•••" : "\(entry.isOutbound ? "−" : "+")\(XTM.format(entry.amount))")
                .font(.body.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(entry.isOutbound ? Color.primary : .green)
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }

    private var subtitle: String {
        let time = entry.date.formatted(date: .omitted, time: .shortened)
        guard let fee = entry.fee, !model.hideBalance else { return time }
        return "\(time) · includes \(XTM.format(fee)) fee"
    }
}

struct TariReceiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Receive TARI").font(.title2.weight(.semibold))
            if let qr = BrandedQR.image(for: model.ootleAddress) {
                Image(nsImage: qr)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            Text(model.ootleAddress)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text("Your address on Ootle's testnet, for test TARI only (it has no value). Payments to it are private: the address isn't visible on chain.\n\nOn the testnet a payment can take a while to show up here, sometimes hours.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Done") { dismiss() }
                Spacer()
                Button(copied ? "Copied" : "Copy address") {
                    Pasteboard.copy(model.ootleAddress)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

struct TariSendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var amountText = ""
    @State private var fee: MicroTari?
    @State private var feeProblem: String?
    @State private var checkingFee = false
    @State private var reviewing = false
    @State private var sending = false
    @State private var error: String?
    @State private var askingPassword = false
    /// The wallet this screen sends from, fixed when it opens.
    @State private var walletID: UUID?

    private var trimmedRecipient: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var amount: MicroTari? { XTM.parse(amountText) }
    private var addressLooksValid: Bool {
        trimmedRecipient.hasPrefix(Config.ootleAddressPrefix) && trimmedRecipient.count > 40
    }
    private var isOwnAddress: Bool { trimmedRecipient == model.ootleAddress }
    private var total: MicroTari? {
        guard let amount, let fee else { return nil }
        let (sum, overflow) = amount.addingReportingOverflow(fee)
        return overflow ? nil : sum
    }
    private var canReview: Bool {
        addressLooksValid && !isOwnAddress && total.map { $0 <= model.tariBalance } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send TARI").font(.title2.weight(.semibold))

            field("To") {
                TextField("Ootle address (otl_…)", text: $recipient, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...4)
                    .autocorrectionDisabled()
                if isOwnAddress {
                    hint("That's your own address.", warn: true)
                } else if !trimmedRecipient.isEmpty && !addressLooksValid {
                    hint("Not an Ootle testnet address (they start with \(Config.ootleAddressPrefix)).", warn: true)
                }
            }

            field("Amount") {
                HStack {
                    TextField("0.00", text: $amountText)
                        .monospacedDigit()
                    Text("tTARI").foregroundStyle(.secondary)
                }
                if !amountText.trimmingCharacters(in: .whitespaces).isEmpty && amount == nil {
                    hint("Enter just a number, like \(XTM.example). No thousands separators.", warn: true)
                } else if let amount, amount > model.tariBalance {
                    hint("More than your available \(XTM.format(model.tariBalance)) tTARI.", warn: true)
                } else {
                    hint("Available: \(XTM.format(model.tariBalance)) tTARI", warn: false)
                }
            }

            if checkingFee {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working out the exact fee…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let feeProblem {
                hint(feeProblem, warn: true)
            } else if let fee, let total {
                VStack(spacing: 4) {
                    row("Network fee", XTM.format(fee))
                    row("Total", XTM.format(total)).fontWeight(.semibold)
                }
                .font(.callout)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                if total > model.tariBalance {
                    hint("Amount plus fee is more than your available balance.", warn: true)
                }
            }

            hint("The payment is private: amounts and addresses aren't visible on chain. Test TARI only, it has no value.", warn: false)

            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if sending {
                    ProgressView().controlSize(.small)
                    Text("Sending…").foregroundStyle(.secondary)
                }
                Button("Review") { reviewing = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReview || sending || checkingFee)
            }
        }
        .padding(24)
        .frame(width: 400, height: 480)
        .onAppear { walletID = model.ootleWallet }
        // The fee depends on the amount and the funds it spends, so it's worked out again whenever
        // either changes (after a short pause in typing).
        .task(id: "\(trimmedRecipient)|\(amount ?? 0)") { await updateFee() }
        .confirmationDialog("Send \(XTM.format(amount ?? 0)) tTARI?", isPresented: $reviewing, titleVisibility: .visible) {
            Button("Send") { Task { await send() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To \(shortened(trimmedRecipient))\nFee \(XTM.format(fee ?? 0)) tTARI\n\nTransactions can't be reversed.")
        }
        .passwordPrompt("Send \(XTM.format(amount ?? 0)) tTARI", isPresented: $askingPassword) { typed in
            Task { await send(password: typed) }
        }
        .alert("Couldn't send", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private func updateFee() async {
        fee = nil
        feeProblem = nil
        guard addressLooksValid, !isOwnAddress, let amount, amount <= model.tariBalance else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        checkingFee = true
        defer { checkingFee = false }
        do {
            let estimate = try await model.estimateTariFee(to: trimmedRecipient, amount: amount)
            guard !Task.isCancelled else { return }
            fee = estimate
        } catch {
            guard !Task.isCancelled else { return }
            feeProblem = error.localizedDescription
        }
    }

    /// Sends after the password check: Touch ID first if it's on, otherwise (or if that's
    /// cancelled) the password typed into the prompt.
    private func send(password: String? = nil) async {
        guard let amount, let fee else { return }
        sending = true
        defer { sending = false }
        do {
            try await model.sendTari(amount: amount, to: trimmedRecipient, maxFee: fee, from: walletID,
                                     password: password)
            dismiss()
        } catch is AppModel.PasswordNeeded {
            askingPassword = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func shortened(_ address: String) -> String {
        address.count > 24 ? "\(address.prefix(14))…\(address.suffix(8))" : address
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
        .textFieldStyle(.roundedBorder)
    }

    private func hint(_ text: String, warn: Bool) -> some View {
        Text(text).font(.caption).foregroundStyle(warn ? Color.orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text("\(value) tTARI").monospacedDigit() }
    }
}

/// Moves XTM from the main chain to this wallet's TARI side: the XTM is burnt, and Clew claims the
/// same amount (less a small Ootle fee) as TARI about a day later. One way only.
struct MoveToTariView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var tiers = FeeTiers.fallback
    @State private var understandsOneWay = false
    @State private var understandsWait = false
    @State private var moving = false
    @State private var error: String?
    @State private var askingPassword = false
    /// The wallet this screen moves from, fixed when it opens.
    @State private var walletID: UUID?

    private var amount: MicroTari? { XTM.parse(amountText) }
    private var feePerGram: MicroTari { tiers.normal }
    private var fee: MicroTari? { amount.flatMap { model.estimateFee(amount: $0, feePerGram: feePerGram) } }
    private var total: MicroTari? {
        guard let amount, let fee else { return nil }
        let (sum, overflow) = amount.addingReportingOverflow(fee)
        return overflow ? nil : sum
    }
    private var canMove: Bool {
        model.canMoveToTari && understandsOneWay && understandsWait && !moving
            && total.map { $0 <= model.balance.available } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move XTM to TARI").font(.title2.weight(.semibold))

            if !model.canMoveToTari {
                Label {
                    Text("Available when Ootle launches. Ootle is still on its testnet, while your wallets are on Tari's main network: XTM moved there now would be lost, so Clew won't do it.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.callout)
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("Your XTM is burnt on Tari's main chain, and the same amount arrives here as TARI, less a small Ootle fee. Clew claims it for you once Ootle accepts it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Amount").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    HStack {
                        TextField("0.00", text: $amountText)
                            .textFieldStyle(.roundedBorder)
                            .monospacedDigit()
                        Text("XTM").foregroundStyle(.secondary)
                    }
                    if !amountText.trimmingCharacters(in: .whitespaces).isEmpty && amount == nil {
                        hint("Enter just a number, like \(XTM.example). No thousands separators.", warn: true)
                    } else {
                        hint("Available: \(XTM.format(model.balance.available)) XTM", warn: false)
                    }
                }

                if let fee, let total {
                    VStack(spacing: 4) {
                        row("Network fee", XTM.format(fee))
                        row("Total", XTM.format(total)).fontWeight(.semibold)
                    }
                    .font(.callout)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    if total > model.balance.available {
                        hint("Amount plus fee is more than your available balance.", warn: true)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("I understand this is one-way: TARI can't be turned back into XTM.", isOn: $understandsOneWay)
                    Toggle("I understand the TARI takes about a day to arrive.", isOn: $understandsWait)
                }
                .toggleStyle(.checkbox)
                .font(.callout)
            }
            .disabled(!model.canMoveToTari)

            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if moving { ProgressView().controlSize(.small) }
                Button("Move \(amount.map { XTM.format($0) } ?? "") XTM") { Task { await move() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canMove)
            }
        }
        .padding(24)
        .frame(width: 420, height: 560)
        .task { if model.canMoveToTari { tiers = await model.feeTiers() } }
        .onAppear { walletID = model.activeID }
        .passwordPrompt("Move \(XTM.format(amount ?? 0)) XTM to TARI", isPresented: $askingPassword) { typed in
            Task { await move(password: typed) }
        }
        .alert("Couldn't move", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private func move(password: String? = nil) async {
        guard let amount else { return }
        moving = true
        defer { moving = false }
        do {
            try await model.moveToTari(amount: amount, feePerGram: feePerGram, from: walletID, password: password)
            dismiss()
        } catch is AppModel.PasswordNeeded {
            askingPassword = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func hint(_ text: String, warn: Bool) -> some View {
        Text(text).font(.caption).foregroundStyle(warn ? Color.orange : .secondary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text("\(value) XTM").monospacedDigit() }
    }
}
