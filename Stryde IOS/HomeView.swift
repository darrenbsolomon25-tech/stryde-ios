import SwiftUI
import MapKit
import ClerkKit

struct HomeView: View {
    @State private var locationManager = LocationManager()
    // .userLocation follows the device GPS; if permission is pending it shows the world.
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)

    @State private var quickRunActive = false
    @State private var selectedDistance: String? = nil
    @State private var customDistance = ""
    @State private var loading = false

    // Holds the route that was just generated — set right before we navigate.
    @State private var generatedRoute: GeneratedRoute? = nil
    @State private var routeSnappedCoord: CLLocationCoordinate2D? = nil
    @State private var navigateToPreview = false

    // Stored for the "Try from there" flow when backend returns a suggestedStart.
    @State private var pendingSuggestion: SuggestedStart? = nil
    @State private var showSuggestionAlert = false
    @State private var showSnapAlert = false
    @State private var snapMessage = ""
    @State private var errorMessage: String? = nil

    private var appState = AppState.shared

    // Distance options adjust to the user's fitness level, same as the RN app.
    private var quickDistances: [String] {
        switch appState.userProfile?.fitnessLevel {
        case "Advanced": return ["3 mi", "5 mi", "8 mi"]
        case "Intermediate": return ["2 mi", "3 mi", "5 mi"]
        default: return ["1 mi", "2 mi", "3 mi"]
        }
    }

    private var coordinate: CLLocationCoordinate2D? {
        locationManager.coordinate
    }

    var body: some View {
        ZStack(alignment: .leading) {
            mainContent

            // Dimmed scrim — tap it to close the drawer.
            if appState.drawerOpen {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { appState.drawerOpen = false }
                    }
                DrawerView()
                    .transition(.move(edge: .leading))
            }
        }
        // navigationDestination fires as soon as navigateToPreview flips to true.
        .navigationDestination(isPresented: $navigateToPreview) {
            if let route = generatedRoute {
                RoutePreviewView(
                    route: route,
                    location: routeSnappedCoord ?? coordinate ?? CLLocationCoordinate2D(),
                    genParams: GenParams(
                        profile: appState.userProfile,
                        distance: selectedDistance ?? (customDistance + " mi"),
                        customRequest: nil,
                        routeType: "loop"
                    )
                )
            }
        }
        .navigationBarHidden(true)
        // Drawer navigation destinations — set by DrawerView's buttons.
        // SwiftUI resets these to false automatically when the user pops back.
        .navigationDestination(isPresented: Bindable(appState).showRunHistory) {
            RunHistoryView()
        }
        .navigationDestination(isPresented: Bindable(appState).showSettings) {
            SettingsView()
        }
        .alert("Better start nearby", isPresented: $showSuggestionAlert, presenting: pendingSuggestion) { suggestion in
            Button("Cancel", role: .cancel) {}
            Button("Try from there") {
                let dist = selectedDistance ?? (customDistance + " mi")
                Task { await generateFrom(suggestion: suggestion, distance: dist) }
            }
        } message: { suggestion in
            Text("No loop from here. Walk ~\(Int(suggestion.walkMeters))m \(suggestion.direction) for a cleaner route.")
        }
        .alert("Route Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Your loop starts nearby", isPresented: $showSnapAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Walk there →") { navigateToPreview = true }
        } message: {
            Text(snapMessage)
        }
    }

    // MARK: - Main layout

    private var mainContent: some View {
        VStack(spacing: 0) {
            headerBar
            mapSection
            bottomPanel
        }
        .background(Color(hex: "#27272D"))
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                // Clerk gives us the signed-in user's first name.
                Text("Good run, \(Clerk.shared.user?.firstName ?? "Runner")")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                Text("Where are we going today?")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "#888888"))
            }
            Spacer()
            // Hamburger button — three bars, same look as the RN version.
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { appState.drawerOpen = true }
            } label: {
                VStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white)
                            .frame(width: 18, height: 2)
                    }
                }
                .frame(width: 40, height: 40)
                .background(Color(hex: "#1A1A1A"))
                .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var mapSection: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .realistic))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
        // This overlay shows when location hasn't been acquired yet.
        .overlay {
            if coordinate == nil {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(hex: "#1A1A1A"))
                    .overlay {
                        Text(locationManager.authorizationStatus == .denied
                             ? "Location permission denied"
                             : "Getting your location...")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#888888"))
                    }
                    .padding(.horizontal, 20)
            }
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 8) {
            if quickRunActive {
                // DISTANCE PICKER — shown after tapping Quick Run
                Text("PICK YOUR DISTANCE")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "#888888"))
                    .kerning(1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    ForEach(quickDistances, id: \.self) { d in
                        Button {
                            selectedDistance = d
                            Task { await handleQuickRun(distance: d) }
                        } label: {
                            Group {
                                if selectedDistance == d && loading {
                                    ProgressView().tint(.white).scaleEffect(0.8)
                                } else {
                                    Text(d)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(hex: "#1A1A1A"))
                            .cornerRadius(14)
                        }
                        .disabled(loading)
                    }
                    // Free-type custom distance field
                    TextField("mi", text: $customDistance)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(hex: "#1A1A1A"))
                        .cornerRadius(14)
                        .onSubmit {
                            if !customDistance.isEmpty {
                                selectedDistance = nil
                                Task { await handleQuickRun(distance: customDistance + " mi") }
                            }
                        }
                }

                Button("Cancel") { quickRunActive = false; selectedDistance = nil; customDistance = "" }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(hex: "#888888"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)

            } else {
                // DEFAULT STATE — two main action buttons
                Button {
                    if coordinate != nil { quickRunActive = true }
                } label: {
                    Text("Quick Run")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: "#27272D"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "#C6F135").opacity(coordinate != nil ? 1 : 0.4))
                        .cornerRadius(16)
                }
                .disabled(coordinate == nil)

                NavigationLink {
                    if let coord = coordinate {
                        BuildRunView(
                            profile: appState.userProfile,
                            coordinate: coord
                        )
                    }
                } label: {
                    Text("Build My Run")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "#1A1A1A").opacity(coordinate != nil ? 1 : 0.4))
                        .cornerRadius(16)
                }
                .disabled(coordinate == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    // MARK: - Route generation

    private func handleQuickRun(distance: String) async {
        guard let coord = coordinate else { return }
        loading = true
        defer { loading = false }

        do {
            let miles = parseMiles(distance)
            let result = try await APIService.shared.generateRoute(
                profile: appState.userProfile,
                latitude: coord.latitude,
                longitude: coord.longitude,
                distanceMiles: miles,
                customRequest: nil,
                routeType: "loop"
            )
            switch result {
            case .suggestedStart(let suggestion):
                pendingSuggestion = suggestion
                showSuggestionAlert = true
            case .route(let route):
                generatedRoute = route
                let w0 = route.waypoints.first
                let snapDist = w0.map {
                    haversineDistanceMiles(coord.latitude, coord.longitude, $0.latitude, $0.longitude) * 1609.34
                } ?? 0
                if snapDist > 150, let w0 {
                    let dir = bearingCardinal(coord.latitude, coord.longitude, w0.latitude, w0.longitude)
                    routeSnappedCoord = coord
                    snapMessage = "Walk ~\(Int(snapDist))m \(dir) to reach your starting point."
                    showSnapAlert = true
                } else {
                    routeSnappedCoord = coord
                    quickRunActive = false
                    selectedDistance = nil
                    customDistance = ""
                    navigateToPreview = true
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            print("[HomeView] generateRoute failed: \(error.localizedDescription)")
        }
    }

    private func generateFrom(suggestion: SuggestedStart, distance: String) async {
        loading = true
        defer { loading = false }
        do {
            let miles = parseMiles(distance)
            let result = try await APIService.shared.generateRoute(
                profile: appState.userProfile,
                latitude: suggestion.lat,
                longitude: suggestion.lng,
                distanceMiles: miles,
                customRequest: nil,
                routeType: "loop"
            )
            if case .route(let route) = result {
                generatedRoute = route
                routeSnappedCoord = CLLocationCoordinate2D(latitude: suggestion.lat, longitude: suggestion.lng)
                quickRunActive = false
                selectedDistance = nil
                customDistance = ""
                navigateToPreview = true
            }
        } catch {
            print("[HomeView] suggestion retry failed: \(error.localizedDescription)")
        }
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
}
