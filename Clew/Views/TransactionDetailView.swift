import SwiftUI

/// Everything about one transaction, in plain words, plus a payment proof to share.
struct TransactionDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tx: WalletTransaction
    @State private var records: [PaymentRecord] = []
    @State private var copied: String?

    private static let minutesPerBlock = 2.0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusCard
                    details
                    proof
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440, height: 600)
        .onAppear { records = model.paymentRecords(for: tx) }
        .onChange(of: model.transactions) { records = model.paymentRecords(for: tx) }
    }

    /// The live copy of this transaction, so the status updates while the sheet is open.
    private var current: WalletTransaction { model.transactions.first { $0.id == tx.id } ?? tx }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(current.isOutbound ? "Sent" : "Received")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("\(current.isOutbound ? "−" : "+")\(XTM.format(current.amount)) XTM")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(current.isOutbound ? Color.primary : .green)
                .textSelection(.enabled)
            Text(current.date.formatted(date: .long, time: .shortened))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        let (icon, color, title, detail) = statusText
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = confirmationProgress {
                    ProgressView(value: progress).tint(color).padding(.top, 4)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var tip: UInt64 { model.scannedHeight }
    private var required: UInt64 { model.confirmationsRequired }

    private var confirmations: UInt64? {
        guard let mined = current.minedHeight, tip >= mined else { return nil }
        return tip - mined + 1
    }

    private var confirmationProgress: Double? {
        guard current.status == .confirming, let confirmations else { return nil }
        return min(Double(confirmations) / Double(max(required, 1)), 1)
    }

    private var statusText: (String, Color, String, String) {
        switch current.status {
        case .pending, .broadcast:
            return ("clock", .orange, "Waiting for a block",
                    current.isOutbound
                        ? "Sent to the network. It's usually added to a block within a few minutes."
                        : "On its way. It's usually added to a block within a few minutes.")
        case .confirming:
            let done = confirmations ?? 0
            let left = required > done ? required - done : 0
            return ("hourglass", .orange, "Confirming — \(done) of \(required)",
                    "In a block. It becomes final after \(required) confirmations, \(time(blocks: left)) from now.")
        case .confirmed:
            return ("checkmark.seal.fill", .green, "Confirmed",
                    "This payment is final and can't be reversed.")
        case .locked:
            if current.lockHeight > tip {
                return ("lock.fill", .secondary, "Confirmed, funds locked",
                        "These funds can be spent from block \(current.lockHeight.formatted()), \(time(blocks: current.lockHeight - tip)) from now.")
            }
            return ("lock.fill", .secondary, "Confirmed, funds locked",
                    "These funds unlock after a waiting period. Mined coins, for example, wait about 6 hours.")
        case .rejected:
            return ("xmark.octagon.fill", .red, "Rejected",
                    "The network refused this transaction. No money moved.")
        case .cancelled:
            return ("xmark.circle.fill", .secondary, "Cancelled",
                    "This transaction was cancelled. No money moved.")
        }
    }

    private func time(blocks: UInt64) -> String {
        let minutes = Double(blocks) * Self.minutesPerBlock
        if minutes < 1 { return "moments" }
        if minutes < 90 { return "about \(Int(minutes.rounded())) min" }
        return "about \(Int((minutes / 60).rounded())) hours"
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(current.isOutbound ? "To" : "From") {
                if let address = current.counterparty {
                    copyable(address, label: "address")
                } else {
                    Text(current.isOutbound ? "Unknown" : "Hidden — stealth payments don't reveal the sender.")
                        .foregroundStyle(.secondary)
                }
            }
            if !current.note.isEmpty {
                row("Note") { Text(current.note).textSelection(.enabled) }
            }
            if current.isOutbound {
                row("Network fee") { Text("\(XTM.format(current.fee)) XTM").monospacedDigit() }
            }
            if let mined = current.minedHeight {
                row("Block") { Text(mined.formatted()).monospacedDigit() }
            }
            row("Transaction ID") { copyable(String(current.id), label: "ID") }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var proof: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payment proof").font(.headline)
            if records.isEmpty {
                Text("A payment reference appears here once this transaction is in a block.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Share this reference to prove the payment. The other person can look it up in their own wallet. It doesn't reveal anything else about your wallet.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(records, id: \.reference) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.reference)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack {
                            Text("\(XTM.format(record.amount)) XTM · block \(record.blockHeight.formatted())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(copied == record.reference ? "Copied" : "Copy") {
                                Pasteboard.copy(record.reference)
                                copied = record.reference
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func copyable(_ text: String, label: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(copied == text ? "Copied" : "Copy") {
                Pasteboard.copy(text)
                copied = text
            }
            .controlSize(.small)
            .help("Copy \(label)")
        }
    }
}
