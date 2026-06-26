import SwiftUI
import CoreLocation

private let TERRAINS = ["Parks", "Waterfront", "Hills", "Flat Roads", "Trails", "Urban Streets"]

struct BuildRunView: View {
    let profile: UserProfile?
    let coordinate: CLLocationCoordinate2D

    @State private var routeType = "loop"
    @State private var selectedDistance: String? = nil
    @State private var customDistance = ""
    @State private var selectedTerrain: [String]
    @State private var selectedElevation = "flat"
    @State private var customRequest = ""
    @State private var loading = false
    // Flips true if the runner taps Generate without picking a distance — drives the
    // red "pick a distance" banner. Distance is the ONLY required field; terrain,
    // elevation and special requests are all optional, so nothing else gates this.
    @State private var showDistanceError = false

    @State private var generatedRoute: GeneratedRoute? = nil
    @State private var routeCoord: CLLocationCoordinate2D? = nil
    @State private var navigateToPreview = false

    @State private var pendingSuggestion: SuggestedStart? = nil
    @State private var showSuggestionAlert = false
    @State private var showSnapAlert = false
    @State private var snapMessage = ""
    @State private var errorMessage: String? = nil

    // Pre-fill terrain from the user's profile, same as the RN screen does.
    init(profile: UserProfile?, coordinate: CLLocationCoordinate2D) {
        self.profile = profile
        self.coordinate = coordinate
        _selectedTerrain = State(initialValue: profile?.terrain ?? [])
    }

    private var quickDistances: [String] {
        switch profile?.fitnessLevel {
        case "Advanced": return ["3 mi", "5 mi", "8 mi"]
        case "Intermediate": return ["2 mi", "3 mi", "5 mi"]
        default: return ["1 mi", "2 mi", "3 mi"]
        }
    }

    private var canGenerate: Bool { selectedDistance != nil || !customDistance.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                buildLabel("Route Type")
                segmentedControl(
                    options: [("loop", "Loop"), ("one-way", "One Way")],
                    selected: $routeType
                )
                .padding(.bottom, 20)

                buildLabel("Distance")
                chipRow(
                    options: quickDistances,
                    selected: Binding(
                        get: { selectedDistance },
                        set: {
                            selectedDistance = $0
                            if $0 != nil { customDistance = ""; showDistanceError = false }
                        }
                    )
                )
                // Custom distance text field mixed in with the chips
                TextField("mi", text: $customDistance)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(customDistance.isEmpty ? Color(hex: "#888888") : .white)
                    .frame(width: 64)
                    .padding(.vertical, 10)
                    .background(customDistance.isEmpty ? Color(hex: "#1A1A1A") : Color(hex: "#C6F135"))
                    .cornerRadius(12)
                    .onChange(of: customDistance) { _, newValue in
                        selectedDistance = nil
                        if !newValue.isEmpty { showDistanceError = false }
                    }
                    .padding(.bottom, 20)

                buildLabel("Terrain")
                flowChipGrid(options: TERRAINS, selected: $selectedTerrain)
                    .padding(.bottom, 20)

                buildLabel("Elevation")
                segmentedControl(
                    options: [("flat", "Flat"), ("mixed", "Mixed"), ("hilly", "Hilly")],
                    selected: $selectedElevation
                )
                .padding(.bottom, 20)

                buildLabel("Special Requests")
                TextEditor(text: $customRequest)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(minHeight: 90)
                    .background(Color(hex: "#1A1A1A"))
                    .cornerRadius(14)
                    .overlay(
                        // Placeholder text — TextEditor doesn't have a built-in placeholder.
                        Group {
                            if customRequest.isEmpty {
                                Text("e.g. run past the waterfront, avoid busy streets...")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(hex: "#555555"))
                                    .padding(16)
                                    .allowsHitTesting(false)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                        }
                    )
                    .padding(.bottom, 24)

                // Red validation banner — shown only after a tap with no distance set.
                if showDistanceError {
                    distanceErrorBanner
                }

                Button {
                    // Distance is the only requirement. If it's missing, surface the red
                    // banner instead of silently doing nothing, and don't call the API.
                    guard canGenerate else {
                        withAnimation { showDistanceError = true }
                        return
                    }
                    showDistanceError = false
                    Task { await handleGenerate() }
                } label: {
                    Group {
                        if loading {
                            HStack(spacing: 8) {
                                ProgressView().tint(Color(hex: "#27272D"))
                                Text("Building your route...")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(Color(hex: "#27272D"))
                            }
                        } else {
                            Text("Generate My Route")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Color(hex: "#27272D"))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "#C6F135").opacity(canGenerate && !loading ? 1 : 0.3))
                    .cornerRadius(16)
                }
                // Only blocked while a request is in flight. When distance is missing the
                // button stays tappable (dimmed) so the tap can trigger the red banner.
                .disabled(loading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Color(hex: "#27272D").ignoresSafeArea())
        .navigationTitle("Build My Run")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(isPresented: $navigateToPreview) {
            if let route = generatedRoute {
                RoutePreviewView(
                    route: route,
                    location: routeCoord ?? coordinate,
                    genParams: buildGenParams()
                )
            }
        }
        .alert("Better start nearby", isPresented: $showSuggestionAlert, presenting: pendingSuggestion) { s in
            Button("Cancel", role: .cancel) {}
            Button("Try from there") { Task { await generateFromSuggestion(s) } }
        } message: { s in
            Text("No loop from here. Walk ~\(Int(s.walkMeters))m \(s.direction) for a cleaner route.")
        }
        .alert("Your loop starts nearby", isPresented: $showSnapAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Walk there →") { navigateToPreview = true }
        } message: { Text(snapMessage) }
        .alert("Route Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Generation

    private func handleGenerate() async {
        let distance = customDistance.isEmpty ? (selectedDistance ?? "3 mi") : (customDistance + " mi")
        loading = true
        defer { loading = false }
        do {
            let fullRequest = [customRequest, "Elevation preference: \(selectedElevation)"]
                .filter { !$0.isEmpty }.joined(separator: ". ")
            let modifiedProfile: UserProfile? = profile.map { p in
                var copy = p; copy.terrain = selectedTerrain; return copy
            }
            let result = try await APIService.shared.generateRoute(
                profile: modifiedProfile,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                distanceMiles: parseMiles(distance),
                customRequest: fullRequest.isEmpty ? nil : fullRequest,
                routeType: routeType
            )
            switch result {
            case .suggestedStart(let s):
                pendingSuggestion = s; showSuggestionAlert = true
            case .route(let route):
                generatedRoute = route
                let w0 = route.waypoints.first
                let snapDist = w0.map {
                    haversineDistanceMiles(coordinate.latitude, coordinate.longitude, $0.latitude, $0.longitude) * 1609.34
                } ?? 0
                if snapDist > 150, let w0 {
                    let dir = bearingCardinal(coordinate.latitude, coordinate.longitude, w0.latitude, w0.longitude)
                    routeCoord = coordinate
                    snapMessage = "Walk ~\(Int(snapDist))m \(dir) to reach your starting point."
                    showSnapAlert = true
                } else {
                    routeCoord = coordinate
                    navigateToPreview = true
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            print("[BuildRunView] generate failed: \(error.localizedDescription)")
        }
    }

    private func generateFromSuggestion(_ s: SuggestedStart) async {
        let distance = customDistance.isEmpty ? (selectedDistance ?? "3 mi") : (customDistance + " mi")
        loading = true
        defer { loading = false }
        do {
            let fullRequest = [customRequest, "Elevation preference: \(selectedElevation)"]
                .filter { !$0.isEmpty }.joined(separator: ". ")
            let modifiedProfile: UserProfile? = profile.map { p in
                var copy = p; copy.terrain = selectedTerrain; return copy
            }
            let result = try await APIService.shared.generateRoute(
                profile: modifiedProfile,
                latitude: s.lat, longitude: s.lng,
                distanceMiles: parseMiles(distance),
                customRequest: fullRequest.isEmpty ? nil : fullRequest,
                routeType: routeType
            )
            if case .route(let route) = result {
                generatedRoute = route
                routeCoord = CLLocationCoordinate2D(latitude: s.lat, longitude: s.lng)
                navigateToPreview = true
            }
        } catch {
            errorMessage = error.localizedDescription
            print("[BuildRunView] suggestion retry failed: \(error.localizedDescription)")
        }
    }

    private func buildGenParams() -> GenParams {
        let distance = customDistance.isEmpty ? (selectedDistance ?? "3 mi") : (customDistance + " mi")
        let fullRequest = [customRequest, "Elevation preference: \(selectedElevation)"]
            .filter { !$0.isEmpty }.joined(separator: ". ")
        var modifiedProfile = profile
        modifiedProfile?.terrain = selectedTerrain
        return GenParams(
            profile: modifiedProfile,
            distance: distance,
            customRequest: fullRequest.isEmpty ? nil : fullRequest,
            routeType: routeType
        )
    }

    // MARK: - Sub-views

    // Pulled out of `body` so the main view builder stays small and fast to type-check.
    private var distanceErrorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Pick a distance first — it's the one thing we need to build your route.")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(Color(hex: "#FF3B30"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(hex: "#FF3B30").opacity(0.12))
        .cornerRadius(12)
        .padding(.bottom, 12)
        .transition(.opacity)
    }

    private func buildLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color(hex: "#888888"))
            .kerning(1.5)
            .textCase(.uppercase)
            .padding(.bottom, 8)
    }

    private func segmentedControl(options: [(String, String)], selected: Binding<String>) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selected.wrappedValue = value
                } label: {
                    Text(label)
                        .font(.system(size: 14, weight: selected.wrappedValue == value ? .bold : .medium))
                        .foregroundColor(selected.wrappedValue == value ? Color(hex: "#27272D") : Color(hex: "#888888"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selected.wrappedValue == value ? Color(hex: "#C6F135") : Color.clear)
                        .cornerRadius(11)
                }
                .padding(3)
            }
        }
        .background(Color(hex: "#1A1A1A"))
        .cornerRadius(14)
    }

    private func chipRow(options: [String], selected: Binding<String?>) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { opt in
                Button {
                    selected.wrappedValue = opt
                } label: {
                    Text(opt)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(selected.wrappedValue == opt ? Color(hex: "#27272D") : Color(hex: "#888888"))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(selected.wrappedValue == opt ? Color(hex: "#C6F135") : Color(hex: "#1A1A1A"))
                        .cornerRadius(12)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func flowChipGrid(options: [String], selected: Binding<[String]>) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { opt in
                let isOn = selected.wrappedValue.contains(opt)
                Button {
                    if isOn {
                        selected.wrappedValue.removeAll { $0 == opt }
                    } else {
                        selected.wrappedValue.append(opt)
                    }
                } label: {
                    Text(opt)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isOn ? Color(hex: "#27272D") : Color(hex: "#888888"))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(isOn ? Color(hex: "#C6F135") : Color(hex: "#1A1A1A"))
                        .cornerRadius(12)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        BuildRunView(
            profile: UserProfile(fitnessLevel: "Intermediate", terrain: ["Parks"], preferredDistance: "2 - 4 miles", goals: ["Get fit"]),
            coordinate: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        )
    }
}
