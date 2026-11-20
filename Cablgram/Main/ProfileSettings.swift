import SwiftUI

/// Menu tab: your name, date of birth and phone number, each changeable.
struct ProfileSettings: View {
    @EnvironmentObject private var auth: AuthStore

    private enum Editing: String, Identifiable {
        case name, birthday, phone
        var id: String { rawValue }
    }

    @State private var editing: Editing?

    var body: some View {
        VStack(spacing: 0) {
            row("Name", value: auth.displayName, icon: "person") { editing = .name }
            Divider().padding(.leading, 52)
            row("Date of birth", value: auth.dateOfBirth.map(Self.birthdayText) ?? "Not set", icon: "gift") {
                editing = .birthday
            }
            Divider().padding(.leading, 52)
            row("Phone number", value: auth.phoneNumber ?? "Not set", icon: "phone") { editing = .phone }
        }
        .card(cornerRadius: 16)
        .sheet(item: $editing) { item in
            NavigationStack {
                Group {
                    switch item {
                    case .name: NameEditor { editing = nil }
                    case .birthday: BirthdayEditor { editing = nil }
                    case .phone: PhoneEditor { editing = nil }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func row(_ title: String, value: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.press()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(value).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func birthdayText(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC")!
        return date.formatted(style)
    }
}

private struct NameEditor: View {
    @EnvironmentObject private var auth: AuthStore
    let done: () -> Void
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Full name", text: $name)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .navigationTitle("Name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        saving = true
                        defer { saving = false }
                        do { try await auth.saveName(name); done() } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { name = auth.hasName ? auth.displayName : "" }
    }
}

private struct BirthdayEditor: View {
    @EnvironmentObject private var auth: AuthStore
    let done: () -> Void
    @State private var date = Date.now
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Form {
            DatePicker("Date of birth", selection: $date, in: ...Date.now, displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .navigationTitle("Date of birth")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        saving = true
                        defer { saving = false }
                        do { try await auth.saveDateOfBirth(date); done() } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(saving)
            }
        }
        .onAppear {
            // Stored as a UTC calendar day: show that same day in the picker.
            if let saved = auth.dateOfBirth {
                var utc = Calendar(identifier: .gregorian)
                utc.timeZone = TimeZone(identifier: "UTC")!
                let parts = utc.dateComponents([.year, .month, .day], from: saved)
                date = Calendar.current.date(from: parts) ?? saved
            } else {
                date = Calendar.current.date(byAdding: .year, value: -20, to: .now) ?? .now
            }
        }
    }
}

private struct PhoneEditor: View {
    @EnvironmentObject private var auth: AuthStore
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let phone = auth.phoneNumber {
                    Text("Now: \(phone). We'll text a code to the new number.")
                        .foregroundStyle(.secondary)
                }
                PhoneVerifyView(use: auth.phoneNumber == nil ? .link : .change, onDone: done)
            }
            .padding(20)
        }
        .navigationTitle("Phone number")
        .navigationBarTitleDisplayMode(.inline)
    }
}
