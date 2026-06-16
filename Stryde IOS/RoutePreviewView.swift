import SwiftUI
import MapKit
import CoreLocation

struct RoutePreviewView: View {
    @State var route: GeneratedRoute
    let location: CLLocationCoordinate2D
    let genParams: GenParams

    @State private var regenerating = false
    @State private var navigateToRun = false
    @State private var errorMessage: String? = nil

    // Fit the entire route's polyline inside the map frame.
    // This mirrors the `region` useMemo in RoutePreviewScreen.js.
    private var cameraPosition: MapCameraPosition {
        let pts = route.waypoints
        guard !pts.isEmpty else {
            return .region(MKCoordinateRegion(
                center: location,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
        let lats = pts.map(\.latitude)
        let lngs = pts.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLng = lngs.min()!, maxLng = lngs.max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.005),
            longitudeDelta: max((maxLng - minLng) * 1.5, 0.005)
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    private var coords: [CLLocationCoordinate2D] {
        route.waypoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Map with route polyline
            Map(initialPosition: cameraPosition) {
                if coords.count > 1 {
                    MapPolyline(coordinates: coords)
                        .stroke(Color(hex: "#FF6B35"), lineWidth: 5)
                }
                if let first = coords.first {
                    Annotation("Start", coordinate: first) {
                        Circle()
                            .fill(Color(hex: "#FF6B35"))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                if genParams.routeType != "loop", let last = coords.last, coords.count > 1 {
                    Annotation("Finish", coordinate: last) {
                        Circle()
                            .fill(Color(hex: "#FF6B35"))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 20)
            .overlay {
                // Dimmed overlay + spinner while regenerating
                if regenerating {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.black.opacity(0.55))
                        .padding(.horizontal, 20)
                        .overlay {
                            VStack(spacing: 8) {
                                ProgressView().tint(Color(hex: "#C6F135"))
                                Text("Building a new route...")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                            }
                        }
                }
            }

            // Bottom info panel
            VStack(alignment: .leading, spacing: 0) {
                Text(route.routeName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.bottom, 4)

                Text(route.terrainDescription)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#888888"))
                    .lineLimit(2)
                    .padding(.bottom, 12)

                // Stat cards row
                HStack {
                    statCell(value: route.totalDistance, label: "Distance")
                    Divider().frame(height: 30).background(Color(hex: "#333333"))
                    statCell(value: route.estimatedTime, label: "Est. Time")
                    Divider().frame(height: 30).background(Color(hex: "#333333"))
                    statCell(
                        value: route.terrain.isEmpty ? "—" : "\(route.terrain.count)",
                        label: "Terrain"
                    )
                }
                .padding(.vertical, 16)
                .background(Color(hex: "#1A1A1A"))
                .cornerRadius(16)
                .padding(.bottom, 12)

                // Start Run — fires postRouteFeedback(accept) then pushes RunView
                Button {
                    Task { try? await APIService.shared.postRouteFeedback(requestId: route.requestId, event: "accept") }
                    navigateToRun = true
                } label: {
                    Text("Start Run")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: "#27272D"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "#C6F135").opacity(regenerating ? 0.4 : 1))
                        .cornerRadius(16)
                }
                .disabled(regenerating)

                Button {
                    Task { await handleRegenerate() }
                } label: {
                    Text(regenerating ? "Regenerating..." : "Regenerate")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "#1A1A1A").opacity(regenerating ? 0.4 : 1))
                        .cornerRadius(16)
                }
                .disabled(regenerating)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(hex: "#27272D").ignoresSafeArea())
        .navigationTitle("Route Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .alert("Couldn't build a new route", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .navigationDestination(isPresented: $navigateToRun) {
            RunView(route: route, startLocation: location)
        }
    }

    // MARK: - Regenerate

    private func handleRegenerate() async {
        // Tell the reranker this route was rejected before replacing it.
        Task { try? await APIService.shared.postRouteFeedback(requestId: route.requestId, event: "reject") }
        regenerating = true
        defer { regenerating = false }
        do {
            let result = try await APIService.shared.generateRoute(
                profile: genParams.profile,
                latitude: location.latitude,
                longitude: location.longitude,
                distanceMiles: parseMiles(genParams.distance),
                customRequest: genParams.customRequest,
                routeType: genParams.routeType,
                previousRequestId: route.requestId
            )
            if case .route(let newRoute) = result {
                route = newRoute
            }
        } catch {
            errorMessage = error.localizedDescription
            print("[RoutePreviewView] regenerate failed: \(error.localizedDescription)")
        }
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color(hex: "#C6F135"))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#888888"))
                .textCase(.uppercase)
                .kerning(0.5)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    NavigationStack {
        RoutePreviewView(
            route: GeneratedRoute(
                routeName: "Park Loop",
                terrainDescription: "A 3.0-mile loop near you.",
                totalDistance: "3.0 miles",
                estimatedTime: "39 minutes",
                waypoints: [],
                steps: [],
                terrain: ["Parks"],
                requestId: nil
            ),
            location: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
            genParams: GenParams(profile: nil, distance: "3 mi", customRequest: nil, routeType: "loop")
        )
    }
}
