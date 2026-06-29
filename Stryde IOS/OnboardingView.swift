import SwiftUI

private let GENDERS = ["Male", "Female", "Non-binary", "Prefer not to say"]
private let TERRAINS = ["Parks", "Waterfront", "Hills", "Flat Roads", "Trails", "Urban Streets"]
private let DISTANCES = ["Under 2 miles", "2 - 4 miles", "4 - 6 miles", "6+ miles"]
private let GOALS = ["Get fit", "Explore new areas", "Train for a race", "Mental health", "Weight loss"]
private let FITNESS_LEVELS = ["Beginner", "Intermediate", "Advanced"]
private let TOTAL_STEPS = 6

struct OnboardingView: View {
    @State private var step = 0

    // The profile we're building up across steps — mirrors the profile state in OnboardingScreen.js
    @State private var phone = ""
    @State private var age = ""
    @State private var gender = ""
    @State private var fitnessLevel = ""
    @State private var terrain: [String] = []
    @State private var preferredDistance = ""
    @State private var goals: [String] = []
    // Run / walk / both. Defaults to .both; persisted to AppState in finish().
    @State private var activityMode: ActivityMode = .both

    @State private var saving = false

    // Whether the current step has enough data to continue
    private var canContinue: Bool {
        switch step {
        case 1: return !age.isEmpty && (Int(age) ?? 0) > 0 && !gender.isEmpty
        case 2: return !fitnessLevel.isEmpty
        case 3: return !terrain.isEmpty
        case 4: return !preferredDistance.isEmpty
        case 5: return !goals.isEmpty
        default: return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar — hidden on welcome step, same as RN
            if step > 0 {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: "#333333"))
                        .frame(height: 3)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hex: "#C6F135"))
                            .frame(width: geo.size.width * CGFloat(step) / CGFloat(TOTAL_STEPS - 1), height: 3)
                            // animates the bar filling as you advance steps
                            .animation(.easeInOut(duration: 0.3), value: step)
                    }
                    .frame(height: 3)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }

            ScrollView {
                // .transition makes the new step slide in from the right when step advances
                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: aboutStep
                    case 2: fitnessStep
                    case 3: terrainStep
                    case 4: distanceStep
                    case 5: goalsStep
                    default: EmptyView()
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing),
                    removal: .move(edge: .leading)
                ))
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 32)
            }
        }
        .background(Color(hex: "#27272D").ignoresSafeArea())
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("YOUR AI RUNNING COACH")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(hex: "#C6F135"))
                .kerning(3)
                .padding(.bottom, 24)

            Text("Run smarter.\nEvery time.")
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(.white)
                .lineSpacing(4)
                .padding(.bottom, 24)

            Text("We learn how you run, what you love, and build the perfect route — every single time.")
                .font(.system(size: 16))
                .foregroundColor(Color(hex: "#888888"))
                .lineSpacing(6)
                .padding(.bottom, 48)

            Spacer()

            actionButton("Get Started", enabled: true) { advance() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aboutStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            questionText("A little\nabout you")

            fieldLabel("Age")
            TextField("30", text: $age)
                .keyboardType(.numberPad)
                .onChange(of: age) { _, new in
                    age = new.filter { $0.isNumber }
                }
                .strydeCard()
                .padding(.bottom, 16)

            fieldLabel("Gender")
            FlowLayout(spacing: 8) {
                ForEach(GENDERS, id: \.self) { g in
                    pillButton(g, selected: gender == g) {
                        gender = g
                    }
                }
            }
            .padding(.bottom, 24)

            fieldLabel("Phone (optional)")
            TextField("+1 555 555 5555", text: $phone)
                .keyboardType(.phonePad)
                .strydeCard()
                .padding(.bottom, 32)

            actionButton("Continue", enabled: canContinue) { advance() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fitnessStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            questionText("What's your\nfitness level?")
            ForEach(FITNESS_LEVELS, id: \.self) { level in
                cardButton(level, selected: fitnessLevel == level) {
                    fitnessLevel = level
                }
            }

            Spacer().frame(height: 28)
            // Run / walk / both. Sets the app's default activity + on-screen
            // language; only "both" shows a Run/Walk toggle on the generate screens.
            fieldLabel("Are you here to…")
            ForEach(ActivityMode.allCases, id: \.self) { mode in
                cardButton(mode.label, selected: activityMode == mode) {
                    activityMode = mode
                }
            }

            Spacer().frame(height: 32)
            actionButton("Continue", enabled: canContinue) { advance() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var terrainStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            questionText("What terrain\ndo you love?")
            Text("Select all that apply")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#888888"))
                .padding(.bottom, 16)
                .padding(.top, -16)
            ForEach(TERRAINS, id: \.self) { t in
                cardButton(t, selected: terrain.contains(t)) {
                    toggle(&terrain, value: t)
                }
            }
            Spacer().frame(height: 32)
            actionButton("Continue", enabled: canContinue) { advance() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var distanceStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            questionText("How far do you\nusually run?")
            ForEach(DISTANCES, id: \.self) { d in
                cardButton(d, selected: preferredDistance == d) {
                    preferredDistance = d
                }
            }
            Spacer().frame(height: 32)
            actionButton("Continue", enabled: canContinue) { advance() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            questionText("What are\nyour goals?")
            Text("Select all that apply")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#888888"))
                .padding(.bottom, 16)
                .padding(.top, -16)
            ForEach(GOALS, id: \.self) { g in
                cardButton(g, selected: goals.contains(g)) {
                    toggle(&goals, value: g)
                }
            }
            Spacer().frame(height: 32)
            actionButton("Let's Run", enabled: canContinue, loading: saving) { finish() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Logic

    private func advance() {
        withAnimation { step += 1 }
    }

    private func toggle(_ array: inout [String], value: String) {
        if array.contains(value) {
            array.removeAll { $0 == value }
        } else {
            array.append(value)
        }
    }

    private func finish() {
        saving = true
        let profile = UserProfile(
            fitnessLevel: fitnessLevel,
            terrain: terrain,
            preferredDistance: preferredDistance,
            goals: goals,
            phone: phone.isEmpty ? nil : phone,
            age: age.isEmpty ? nil : age,
            gender: gender.isEmpty ? nil : gender
        )
        // Save locally immediately so the app works offline
        AppState.shared.saveProfile(profile)
        AppState.shared.userProfile = profile

        // Persist the run/walk/both choice (local-only). For a single-mode user,
        // also seed selectedActivity so it's coherent from the first generate.
        AppState.shared.activityMode = activityMode
        if activityMode != .both {
            AppState.shared.selectedActivity = (activityMode == .walk ? .walk : .run)
        }

        // Sync preferences to backend fire-and-forget — same pattern as RN
        Task {
            try? await APIService.shared.putProfile(profile)
        }

        // Flip hasProfile → ContentView switches to Home automatically
        withAnimation { AppState.shared.hasProfile = true }
        saving = false
    }

    // MARK: - Reusable sub-views

    private func questionText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 36, weight: .bold))
            .foregroundColor(.white)
            .lineSpacing(4)
            .padding(.bottom, 32)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color(hex: "#888888"))
            .kerning(1.5)
            .textCase(.uppercase)
            .padding(.bottom, 8)
    }

    private func cardButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(selected ? Color(hex: "#27272D") : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(selected ? Color(hex: "#C6F135") : Color(hex: "#1A1A1A"))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(selected ? Color(hex: "#C6F135") : Color(hex: "#333333"), lineWidth: 1)
                )
        }
        .padding(.bottom, 8)
    }

    private func pillButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(selected ? Color(hex: "#27272D") : .white)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(selected ? Color(hex: "#C6F135") : Color(hex: "#1A1A1A"))
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(selected ? Color(hex: "#C6F135") : Color(hex: "#333333"), lineWidth: 1)
                )
        }
    }

    private func actionButton(_ label: String, enabled: Bool, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if loading {
                ProgressView().tint(Color(hex: "#27272D"))
            } else {
                Text(label)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color(hex: "#27272D"))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color(hex: "#C6F135").opacity(enabled ? 1 : 0.3))
        .cornerRadius(12)
        .disabled(!enabled || loading)
    }
}

// MARK: - FlowLayout (wrapping row of pills — no built-in in SwiftUI)
// This replicates flexWrap: 'wrap' from React Native

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.map { $0.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0 }
                         .reduce(0) { $0 + $1 + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: ProposedViewSize(bounds.size), subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = [[]]
        var rowWidth: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append(subview)
            rowWidth += size.width + spacing
        }
        return rows
    }
}

// MARK: - TextField card style

extension View {
    func strydeCard() -> some View {
        self
            .padding(16)
            .background(Color(hex: "#1A1A1A"))
            .cornerRadius(12)
            .foregroundColor(.white)
            .font(.system(size: 18))
    }
}

#Preview {
    OnboardingView()
}
