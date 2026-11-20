import SwiftUI

/// After signing in, before the app: asks for whatever is still missing of your name,
/// a verified phone number and your date of birth. All can be changed later in Menu.
struct ProfileGateView: View {
    @EnvironmentObject private var auth: AuthStore

    @State private var name = ""
    @State private var birthday = Calendar.current.date(byAdding: .year, value: -20, to: .now) ?? .now
    @State private var pickedBirthday = false
    @State private var saving = false
    @State private var error: String?

    private var needsName: Bool { !auth.hasName }
    private var needsPhone: Bool { auth.phoneNumber == nil }
    private var needsBirthday: Bool { auth.dateOfBirth == nil }

    private var canContinue: Bool {
        !needsPhone
            && (!needsName || !name.trimmingCharacters(in: .whitespaces).isEmpty)
            && (!needsBirthday || pickedBirthday)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Finish your profile").font(.largeTitle.bold())
                    Text("We need these before you start walking for rewards.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                if needsName {
                    section("Your name") {
                        TextField("Full name", text: $name)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                            .padding(.horizontal, 16)
                            .frame(height: 54)
                            .background(Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }

                section("Phone number") {
                    if let phone = auth.phoneNumber {
                        Label(phone, systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                    } else {
                        PhoneVerifyView(use: .link)
                    }
                }

                if needsBirthday {
                    section("Date of birth") {
                        DatePicker("Date of birth", selection: $birthday, in: ...Date.now, displayedComponents: .date)
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .onChange(of: birthday) { pickedBirthday = true }
                        if !pickedBirthday {
                            Text("Scroll to your birthday.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    Task { await save() }
                } label: {
                    ZStack {
                        if saving { ProgressView().tint(.white) } else { Text("Continue").font(.headline) }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.brand, in: Capsule())
                    .opacity(canContinue ? 1 : 0.5)
                }
                .disabled(!canContinue || saving)

                Button("Sign out") {
                    Haptics.warning()
                    auth.signOut()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            if needsName { try await auth.saveName(name) }
            if needsBirthday { try await auth.saveDateOfBirth(birthday) }
            error = nil
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}
