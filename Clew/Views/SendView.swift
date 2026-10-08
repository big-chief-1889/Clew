import SwiftUI

struct SendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var amountText = ""
    @State private var note = ""
    @State private var reviewing = false
    @State private var sending = false
    @State private var error: String?
    @State private var tiers = FeeTiers.fallback
    @State private var tiersLoaded = false
    @State private var speed = Speed.normal
    /// The wallet this screen sends from, fixed when it opens.
    @State private var walletID: UUID?

    enum Speed: String, CaseIterable, Identifiable {
        case economy = "Economy", normal = "Normal", fast = "Fast"
        var id: Self { self }
        var timing: String {
            switch self {
            case .economy: "Cheapest. Matches the lowest fee getting in now, so it may wait a few blocks."
            case .normal: "Just ahead of the cheapest fees waiting. Usually in the next block or two."
            case .fast: "Pays more than everyone waiting, for the next block (about 2 minutes)."
            }
        }
    }

    private var feePerGram: MicroTari {
        guard tiers.networkBusy else { return tiers.normal }
        switch speed {
        case .economy: return tiers.economy
        case .normal: return tiers.normal
        case .fast: return tiers.fast
        }
    }

    private var trimmedRecipient: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var amount: MicroTari? { XTM.parse(amountText) }
    private var recipientNetwork: UInt8? { TariAddress.network(of: trimmedRecipient) }
    private var wrongNetwork: Bool {
        recipientNetwork != nil && recipientNetwork != TariAddress.network(of: model.address)
    }
    private var addressValid: Bool { recipientNetwork != nil && !wrongNetwork }
    private var isOwnAddress: Bool { trimmedRecipient == model.address }
    private var fee: MicroTari? { amount.flatMap { model.estimateFee(amount: $0, feePerGram: feePerGram) } }
    private var total: MicroTari? {
        guard let amount, let fee else { return nil }
        let (sum, overflow) = amount.addingReportingOverflow(fee)
        return overflow ? nil : sum
    }
    private var canReview: Bool {
        addressValid && !isOwnAddress && total.map { $0 <= model.balance.available } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send XTM").font(.title2.weight(.semibold))

            field("To") {
                TextField("Tari address", text: $recipient, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...3)
                    .autocorrectionDisabled()
                if wrongNetwork {
                    hint("This address is for a different Tari network (\(Config.isTestnet ? "not testnet" : "not mainnet")).", warn: true)
                } else if !trimmedRecipient.isEmpty && !addressValid {
                    hint("Not a valid Tari address.", warn: true)
                } else if isOwnAddress {
                    hint("That's your own address.", warn: true)
                }
            }

            field("Amount") {
                HStack {
                    TextField("0.00", text: $amountText)
                        .monospacedDigit()
                    Text("XTM").foregroundStyle(.secondary)
                    Button("Max") { fillMax() }.controlSize(.small)
                }
                if !amountText.trimmingCharacters(in: .whitespaces).isEmpty && amount == nil {
                    hint("Enter just a number, like \(XTM.example). No thousands separators.", warn: true)
                } else {
                    hint("Available: \(XTM.format(model.balance.available)) XTM", warn: false)
                }
            }

            field("Note (optional, visible to the recipient)") {
                TextField("", text: $note)
            }

            field("Speed") {
                if !tiersLoaded {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking how busy the network is…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if tiers.networkBusy {
                    Picker("Speed", selection: $speed) {
                        ForEach(Speed.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    hint(speed.timing, warn: false)
                } else {
                    hint("The network is quiet, so the standard fee goes in the next block (about 2 minutes).", warn: false)
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

            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Review") { reviewing = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReview || sending)
            }
        }
        .padding(24)
        .frame(width: 400, height: 580)
        .task {
            tiers = await model.feeTiers()
            tiersLoaded = true
        }
        .onAppear { walletID = model.activeID }
        .confirmationDialog("Send \(XTM.format(amount ?? 0)) XTM from “\(model.activeWallet?.name ?? "this wallet")”?",
                            isPresented: $reviewing, titleVisibility: .visible) {
            Button("Send") { Task { await send() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To \(shortened(trimmedRecipient))\nFee \(XTM.format(fee ?? 0)) XTM\(tiers.networkBusy ? " (\(speed.rawValue))" : "")\n\nTransactions can't be reversed.")
        }
        .alert("Couldn't send", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private func send() async {
        guard let amount else { return }
        sending = true
        defer { sending = false }
        do {
            try await model.send(amount: amount, to: trimmedRecipient, note: note, feePerGram: feePerGram,
                                 from: walletID)
            dismiss()
        } catch Vault.Failure.cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Largest amount that still leaves room for the fee.
    private func fillMax() {
        let available = model.balance.available
        guard let fee = model.estimateFee(amount: available, feePerGram: feePerGram), available > fee else { return }
        amountText = NSDecimalNumber(value: available - fee).dividing(by: 1_000_000).stringValue
    }

    private func shortened(_ address: String) -> String {
        address.count > 20 ? "\(address.prefix(10))…\(address.suffix(8))" : address
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
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text("\(value) XTM").monospacedDigit() }
    }
}
