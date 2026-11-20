import SwiftUI

/// Type a Bangladeshi number, get a texted code, type the code. Used to sign in, to add
/// a number to an account, and to change it in the Menu tab.
struct PhoneVerifyView: View {
    @EnvironmentObject private var auth: AuthStore

    let use: AuthStore.PhoneUse
    /// White text for the pink sign-in screen.
    var onBrand = false
    var onDone: () -> Void = {}

    @State private var number = ""
    @State private var code = ""
    @State private var verificationID: String?
    @State private var sentTo: String?
    @State private var working = false
    @State private var error: String?
    @State private var resendAt = Date.distantPast
    @FocusState private var focused: Bool

    private var ink: Color { onBrand ? .white : .primary }
    private var faint: Color { onBrand ? .white.opacity(0.85) : .secondary }

    var body: some View {
        VStack(spacing: 12) {
            if let sentTo, verificationID != nil {
                codeStep(sentTo)
            } else {
                numberStep
            }
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(onBrand ? .white : .red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var numberStep: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("🇧🇩 +880")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.black)
                Divider().frame(height: 24)
                TextField("1712 345678", text: $number)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($focused)
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(field)

            primaryButton(title: "Send code", enabled: AuthStore.normalizedPhone(number) != nil) {
                await send()
            }
        }
    }

    private func codeStep(_ phone: String) -> some View {
        VStack(spacing: 12) {
            Text("Enter the 6-digit code we texted to \(phone)")
                .font(.subheadline)
                .foregroundStyle(faint)
                .multilineTextAlignment(.center)
            TextField("123456", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.black)
                .focused($focused)
                .frame(height: 54)
                .background(field)
                .onChange(of: code) { _, new in
                    code = String(new.filter(\.isNumber).prefix(6))
                    if code.count == 6 { Task { await check() } }
                }

            primaryButton(title: "Verify", enabled: code.count == 6) { await check() }

            HStack {
                Button("Change number") {
                    verificationID = nil
                    code = ""
                    error = nil
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = Int(resendAt.timeIntervalSince(context.date).rounded(.up))
                    Button(wait > 0 ? "Resend in \(wait)s" : "Resend code") { Task { await send() } }
                        .disabled(wait > 0 || working)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ink)
        }
    }

    private var field: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(onBrand ? Color.white : Color(.secondarySystemBackground))
    }

    private func primaryButton(title: String, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Haptics.press()
            Task { await action() }
        } label: {
            ZStack {
                if working {
                    ProgressView().tint(onBrand ? .black : .white)
                } else {
                    Text(title).font(.headline)
                }
            }
            .foregroundStyle(onBrand ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(onBrand ? Color.white : Color.brand, in: Capsule())
            .opacity(enabled ? 1 : 0.5)
        }
        .disabled(!enabled || working)
    }

    private func send() async {
        guard let phone = AuthStore.normalizedPhone(number) else {
            error = "Type a Bangladeshi mobile number, like 01712 345678."
            return
        }
        working = true
        defer { working = false }
        do {
            verificationID = try await auth.sendCode(to: phone)
            sentTo = phone
            code = ""
            error = nil
            resendAt = Date().addingTimeInterval(60)
            focused = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func check() async {
        guard let id = verificationID, code.count == 6, !working else { return }
        working = true
        defer { working = false }
        do {
            try await auth.verify(code: code, id: id, use: use)
            error = nil
            focused = false
            onDone()
        } catch {
            self.error = error.localizedDescription
            code = ""
        }
    }
}
