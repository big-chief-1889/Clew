import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.phase {
            case .welcome: WelcomeView().transition(.blurFade)
            case .backup(let words): BackupView(words: words).transition(.blurFade)
            case .locked: LockedView().transition(.blurFade)
            case .unlocked: HomeView().transition(.blurFade)
            case .problem(let message): ProblemView(message: message).transition(.blurFade)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GraphiteBackground())
        .fontDesign(.rounded)
        .animation(.smooth(duration: 0.4), value: model.phase)
        .overlay(alignment: .top) {
            if Config.isTestnet { TestnetBadge() }
        }
        .alert("Something went wrong", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Shown when Clew can't read its wallet list. Nothing can be created or saved from here, so the
/// list (and the wallets it points to) can't be overwritten by accident.
struct ProblemView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Clew can't open your wallets")
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your wallet files haven't been changed. Quit Clew and get help before trying again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Quit Clew") { NSApp.terminate(nil) }
                .buttonStyle(.wide)
                .frame(width: 180)
                .padding(.top, 8)
            Spacer()
        }
        .padding(32)
    }
}
