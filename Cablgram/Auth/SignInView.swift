import SwiftUI

/// First screen: everyone signs in with Google before using the app.
struct SignInView: View {
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        ZStack {
            Color.brand.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 12) {
                    CablgramLogo(size: 64)
                        .padding(.bottom, 8)
                    Text("Read the news. Walk. Win food, games and a PS5.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .opacity(0.9)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 32)

                Spacer()

                VStack(spacing: 14) {
                    Button {
                        Haptics.press()
                        Task { await auth.signInWithGoogle() }
                    } label: {
                        ZStack {
                            if auth.isWorking {
                                ProgressView().tint(.black)
                            } else {
                                Text("Continue with Google")
                                    .font(.headline)
                            }
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(.white, in: Capsule())
                    }
                    .disabled(auth.isWorking)

                    if let error = auth.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }

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
            }
        }
    }
}
