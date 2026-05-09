import SwiftUI
import ClerkKit

private let FITNESS_LEVELS = ["Beginner", "Intermediate", "Advanced"]
private let TERRAINS = ["Parks", "Waterfront", "Hills", "Flat Roads", "Trails", "Urban Streets"]
private let DISTANCES = ["Under 2 miles", "2 - 4 miles", "4 - 6 miles", "6+ miles"]
private let GOALS = ["Get fit", "Explore new areas", "Train for a race", "Mental health", "Weight loss"]
private let GENDERS = ["Male", "Female", "Non-binary", "Prefer not to say"]

struct SettingsView: View {
    private var appState = AppState.shared

    // Local editable copy of the profile.
    @State private var phone = ""
    @State private var age = ""
    @State private var gender = ""
    @State private var fitnessLevel = ""
    @State private var terrain: [String] = []
    @State private var preferredDistance = ""
    @State private var goals: [String] = []

    @State private var deletingAccount = false
    @State private var showDeleteConfirm1 = false
    @State private var showDeleteConfirm2 = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                personalSection
                skillSection
                terrainSection
                distanceSection
                goalsSection

                Button(role: .destructive) {
                    showDeleteConfirm1 = true
                } label: {
                    Text(deletingAccount ? "Deleting account…" : "Delete account")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(hex: "#FF4444"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#FF4444"), lineWidth: 1))
                }
                .disabled(deletingAccount)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Color(hex: "#27272D").ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { loadProfile() }
        // First confirmation
        .alert("Delete account", isPresented: $showDeleteConfirm1) {
            Button("Cancel", role: .cancel) {}
            Button("Delete account", role: .destructive) { showDeleteConfirm2 = true }
        } message: {
            Text("This will permanently delete your account and all your run history. This cannot be undone.")
        }
        // Second hard confirmation — makes it very difficult to tap through by accident.
        .alert("Are you absolutely sure?", isPresented: $showDeleteConfirm2) {
            Button("Cancel", role: .cancel) {}
            Button("Yes, delete everything", role: .destructive) { Task { await deleteAccount() } }
        } message: {
            Text("Your account and all data will be deleted immediately.")
        }
    }

    // MARK: - Collapsible sections
    // DisclosureGroup is SwiftUI's built-in equivalent of the RN CollapsibleSection.

    private var personalSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("Name")
                readonlyField(clerkFullName)

                sectionLabel("Email")
                readonlyField(Clerk.shared.user?.primaryEmailAddress?.emailAddress ?? "—")

                sectionLabel("Phone")
                TextField("+1 555 555 5555", text: $phone)
                    .settingsInput()
                    .onChange(of: phone) { _, v in persist() }

                sectionLabel("Age")
                TextField("30", text: $age)
                    .keyboardType(.numberPad)
                    .settingsInput()
                    .onChange(of: age) { _, v in age = v.filter { $0.isNumber }; persist() }

                sectionLabel("Gender")
                FlowLayout(spacing: 8) {
                    ForEach(GENDERS, id: \.self) { g in
                        settingsPill(g, selected: gender == g) { gender = g; persist() }
                    }
                }
                .padding(.top, 4).padding(.bottom, 8)
            }
        } label: {
            sectionHeader(
                "Personal info",
                summary: Clerk.shared.user?.primaryEmailAddress?.emailAddress ?? "Tap to view"
            )
        }
        .settingsSection()
    }

    private var skillSection: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(FITNESS_LEVELS, id: \.self) { level in
                    settingsCard(level, selected: fitnessLevel == level) {
                        fitnessLevel = level; persist()
                    }
                }
            }
            .padding(.bottom, 8)
        } label: {
            sectionHeader("Skill level", summary: fitnessLevel.isEmpty ? "Not set" : fitnessLevel)
        }
        .settingsSection()
    }

    private var terrainSection: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(TERRAINS, id: \.self) { t in
                    settingsCard(t, selected: terrain.contains(t)) {
                        toggle(&terrain, value: t); persist()
                    }
                }
            }
            .padding(.bottom, 8)
        } label: {
            sectionHeader("Preferred terrain",
                         summary: terrain.isEmpty ? "None selected" : terrain.joined(separator: ", "))
        }
        .settingsSection()
    }

    private var distanceSection: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(DISTANCES, id: \.self) { d in
                    settingsCard(d, selected: preferredDistance == d) {
                        preferredDistance = d; persist()
                    }
                }
            }
            .padding(.bottom, 8)
        } label: {
            sectionHeader("Preferred distance",
                         summary: preferredDistance.isEmpty ? "Not set" : preferredDistance)
        }
        .settingsSection()
    }

    private var goalsSection: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(GOALS, id: \.self) { g in
                    settingsCard(g, selected: goals.contains(g)) {
                        toggle(&goals, value: g); persist()
                    }
                }
            }
            .padding(.bottom, 8)
        } label: {
            sectionHeader("Goals", summary: goals.isEmpty ? "None selected" : goals.joined(separator: ", "))
        }
        .settingsSection()
    }

    // MARK: - Sub-views

    private func sectionHeader(_ title: String, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
            Text(summary)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#888888"))
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color(hex: "#888888"))
            .kerning(1.5)
            .textCase(.uppercase)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private func readonlyField(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 15))
            .foregroundColor(Color(hex: "#888888"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(hex: "#27272D"))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#333333"), lineWidth: 1))
            .padding(.bottom, 4)
    }

    private func settingsCard(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(selected ? Color(hex: "#27272D") : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(selected ? Color(hex: "#C6F135") : Color(hex: "#27272D"))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color(hex: "#C6F135") : Color(hex: "#333333"), lineWidth: 1))
        }
    }

    private func settingsPill(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(selected ? Color(hex: "#27272D") : .white)
                .padding(.vertical, 8).padding(.horizontal, 14)
                .background(selected ? Color(hex: "#C6F135") : Color(hex: "#27272D"))
                .cornerRadius(20)
                .overlay(RoundedRectangle(cornerRadius: 20)
                    .stroke(selected ? Color(hex: "#C6F135") : Color(hex: "#333333"), lineWidth: 1))
        }
    }

    // MARK: - Helpers

    private var clerkFullName: String {
        let name = [Clerk.shared.user?.firstName, Clerk.shared.user?.lastName]
            .compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "—" : name
    }

    // MARK: - Logic

    private func loadProfile() {
        let p = appState.userProfile
        phone = p?.phone ?? ""
        age = p?.age ?? ""
        gender = p?.gender ?? ""
        fitnessLevel = p?.fitnessLevel ?? ""
        terrain = p?.terrain ?? []
        preferredDistance = p?.preferredDistance ?? ""
        goals = p?.goals ?? []
    }

    private func persist() {
        var profile = appState.userProfile ?? UserProfile()
        profile.phone = phone.isEmpty ? nil : phone
        profile.age = age.isEmpty ? nil : age
        profile.gender = gender.isEmpty ? nil : gender
        profile.fitnessLevel = fitnessLevel.isEmpty ? nil : fitnessLevel
        profile.terrain = terrain
        profile.preferredDistance = preferredDistance.isEmpty ? nil : preferredDistance
        profile.goals = goals
        appState.userProfile = profile
        appState.saveProfile(profile)
        // Sync non-PII fields to backend fire-and-forget.
        Task { try? await APIService.shared.putProfile(profile) }
    }

    private func toggle(_ array: inout [String], value: String) {
        if array.contains(value) { array.removeAll { $0 == value } }
        else { array.append(value) }
    }

    private func deleteAccount() async {
        deletingAccount = true
        do {
            // Wipe Postgres data first (JWT still valid at this point).
            try await APIService.shared.deleteAccount()
            // Delete the Clerk account — flips user to nil → ContentView → SignInView.
            try await Clerk.shared.user?.delete()
            // Clear local storage.
            await appState.signOut()
        } catch {
            deletingAccount = false
            print("[Settings] deleteAccount failed: \(error.localizedDescription)")
        }
    }
}

// DisclosureGroup styling extension — keeps the view body clean.
private extension View {
    func settingsSection() -> some View {
        self
            .padding(16)
            .background(Color(hex: "#1A1A1A"))
            .cornerRadius(14)
    }

    func settingsInput() -> some View {
        self
            .font(.system(size: 15))
            .foregroundColor(.white)
            .padding(12)
            .background(Color(hex: "#27272D"))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#333333"), lineWidth: 1))
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
