import SwiftUI

/// First screen: everyone signs in with Google before using the app.
struct SignInView: View {
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        ZStack {
            LinearGradient(colors: [.brand, .brandOrange], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Text("cablgram")
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                VStack(spacing: 8) {
                    Text("News that moves you.")
                        .font(.title3.weight(.semibold))
                    Text("Read the news, walk, climb the leaderboard and win food, games and a PS5.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .opacity(0.9)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 32)

                HStack(spacing: 14) {
                    ForEach(["newspaper.fill", "figure.walk", "trophy.fill", "gamecontroller.fill"], id: \.self) { icon in
                        Image(systemName: icon)
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }

                Spacer()

                VStack(spacing: 14) {
                    Button {
                        Task { await auth.signInWithGoogle() }
                    } label: {
                        HStack(spacing: 10) {
                            if auth.isWorking {
                                ProgressView()
                            } else {
                                Text("G")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(.brandGradient)
                            }
                            Text("Continue with Google")
                                .font(.headline)
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
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
