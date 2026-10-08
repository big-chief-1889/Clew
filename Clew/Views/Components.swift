import SwiftUI

/// The app icon, for welcome and lock screens.
struct AppIconView: View {
    var size: CGFloat = 88
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
    }
}

/// Full-width button for the main actions: `.wide` (filled) or `.wideSecondary` (tinted).
struct WideButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(prominent ? Color.white : Color.accentColor)
            .background(prominent ? Color.accentColor : Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

extension ButtonStyle where Self == WideButtonStyle {
    static var wide: WideButtonStyle { WideButtonStyle(prominent: true) }
    static var wideSecondary: WideButtonStyle { WideButtonStyle(prominent: false) }
}

/// Small circular icon button for toolbars.
struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct TestnetBadge: View {
    var body: some View {
        Text("TESTNET — coins have no value")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(.orange)
            .padding(.top, 6)
    }
}

/// Numbered grid of seed words. Hidden from screenshots and screen sharing.
struct SeedGrid: View {
    let words: [String]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 18, alignment: .trailing)
                    Text(word).fontWeight(.medium)
                    Spacer(minLength: 0)
                }
                .font(.system(.callout, design: .monospaced))
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .textSelection(.disabled)
        .privateWindow()
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension View {
    /// Hides the window this view is in from screenshots, screen recording and screen sharing.
    func privateWindow() -> some View { background(PrivateWindow()) }
}

private struct PrivateWindow: NSViewRepresentable {
    final class Marker: NSView {
        private weak var marked: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            marked?.sharingType = .readOnly
            marked = window
            window?.sharingType = .none
        }
        override func removeFromSuperview() {
            marked?.sharingType = .readOnly
            super.removeFromSuperview()
        }
    }

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}

extension View {
    /// Asks for the Clew password in a small dialog, then calls `submit` with what was typed.
    func passwordPrompt(_ title: String, message: String = "Enter your Clew password.",
                        isPresented: Binding<Bool>, submit: @escaping (String) -> Void) -> some View {
        modifier(PasswordPrompt(title: title, message: message, isPresented: isPresented, submit: submit))
    }
}

private struct PasswordPrompt: ViewModifier {
    let title: String
    let message: String
    @Binding var isPresented: Bool
    let submit: (String) -> Void
    @State private var password = ""

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            SecureField("Password", text: $password)
            Button("OK") {
                let typed = password
                password = ""
                submit(typed)
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { password = "" }
        } message: {
            Text(message)
        }
    }
}

/// Two fields for choosing a password. Any length is allowed; the two just have to match.
struct NewPasswordFields: View {
    @Binding var password: String
    @Binding var confirmation: String

    static func isValid(_ password: String, _ confirmation: String) -> Bool { password == confirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Password", text: $password)
            SecureField("Type it again", text: $confirmation)
            if !confirmation.isEmpty && password != confirmation {
                Text("The two passwords don't match.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("You'll need it to open Clew and to send. If you forget it, restore your wallets from their recovery words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}
