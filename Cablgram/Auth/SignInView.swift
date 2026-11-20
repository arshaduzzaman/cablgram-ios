import SwiftUI

/// First screen: sign in with your phone number (a texted code). The headline types
/// itself out like the ChatGPT app, with a light tick per letter, then the subtitle
/// fades in and the phone field slides up. Tap anywhere to skip to the end.
struct SignInView: View {
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let headline = Array("Walk more. Win real things.")
    private static let subtitle = "Steps turn into food, games and a PS5."

    /// How many letters of the headline are showing.
    @State private var typed = 0
    /// 1 while the caret blinks, down to 0 as it fades out after typing.
    @State private var caret: Double = 1
    @State private var showSubtitle = false
    @State private var showField = false
    @State private var finished = false

    var body: some View {
        ZStack {
            Color.brand.ignoresSafeArea()
                .onTapGesture { skip() }

            VStack(spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 14) {
                    CablgramLogo(size: 56)
                        .padding(.bottom, 10)
                    headline
                    Text(Self.subtitle)
                        .font(.title3)
                        .opacity(showSubtitle ? 0.9 : 0)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .contentShape(Rectangle())
                .onTapGesture { skip() }

                Spacer()

                VStack(spacing: 14) {
                    PhoneVerifyView(use: .signIn, onBrand: true)

                    #if DEBUG
                    if !AuthStore.isConfigured {
                        Button("Skip for now (debug only)") { auth.skippedSignIn = true }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    #endif
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .opacity(showField ? 1 : 0)
                .offset(y: showField ? 0 : 28)
                .allowsHitTesting(showField)
            }
        }
        .task { await play() }
    }

    /// The typed part, a blinking caret, and the rest of the line kept invisible so the
    /// words don't jump around as they appear.
    private var headline: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { context in
            let blinkOn = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0
            let shown = String(Self.headline.prefix(typed))
            let rest = String(Self.headline.dropFirst(typed))
            let caretText = Text("|").foregroundStyle(.white.opacity(caret * (blinkOn ? 1 : 0.15)))
            Text("\(Text(shown))\(caretText)\(Text(rest).foregroundStyle(.clear))")
                .font(.system(size: 38, weight: .heavy))
                .tracking(-0.6)
                .accessibilityLabel(String(Self.headline))
        }
    }

    /// Types the headline (about 40 ms a letter), then fades the caret, the subtitle
    /// and the phone field in. Runs once each time the screen appears.
    private func play() async {
        typed = 0
        caret = 1
        showSubtitle = false
        showField = false
        finished = false
        if reduceMotion {
            finish(animated: false)
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        for index in Self.headline.indices {
            guard !finished, !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(40))
            guard !finished else { return }
            typed = index + 1
            if Self.headline[index] != " " { Haptics.tap() }
        }
        try? await Task.sleep(for: .milliseconds(450))
        guard !finished else { return }
        // Fade the caret out by hand: text colours inside one Text don't animate.
        for step in stride(from: 0.9, through: 0, by: -0.1) {
            guard !finished else { return }
            try? await Task.sleep(for: .milliseconds(25))
            caret = max(step, 0)
        }
        withAnimation(.easeOut(duration: 0.5)) { showSubtitle = true }
        try? await Task.sleep(for: .milliseconds(300))
        guard !finished else { return }
        finish(animated: true)
    }

    /// Tapping the screen jumps to the end.
    private func skip() {
        guard !finished else { return }
        finish(animated: !reduceMotion)
    }

    private func finish(animated: Bool) {
        finished = true
        typed = Self.headline.count
        caret = 0
        if animated {
            withAnimation(.easeOut(duration: 0.4)) { showSubtitle = true }
            withAnimation(.spring(duration: 0.55, bounce: 0.2)) { showField = true }
        } else {
            showSubtitle = true
            showField = true
        }
    }
}
