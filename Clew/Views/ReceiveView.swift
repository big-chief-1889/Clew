import SwiftUI

struct ReceiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Receive XTM").font(.title2.weight(.semibold))
            if let qr = BrandedQR.image(for: model.address) {
                Image(nsImage: qr)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            Text(model.address)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text("This is a one-sided (stealth) address: senders can pay you while this app is closed, and the address isn't visible on the blockchain.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Done") { dismiss() }
                Spacer()
                Button(copied ? "Copied" : "Copy address") {
                    Pasteboard.copy(model.address)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
