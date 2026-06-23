import SwiftUI
import MapKit

struct RunSummaryView: View {
    let run: LocalRun
    let fromHistory: Bool  // true when opened from RunHistoryView — don't re-save

    @Environment(\.dismiss) private var dismiss

    // The run's route as map coordinates. Empty for runs saved before route
    // geometry was stored (older history entries) — the map is hidden then.
    private var coords: [CLLocationCoordinate2D] {
        (run.waypoints ?? []).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    // Fit the whole loop inside the map frame — same bounds-fit math as
    // RoutePreviewView, so the route reads the same here as it did before the run.
    // `.region(...)` builds a MapCameraPosition from a center point plus a span
    // (how many degrees of lat/lng to show); the *1.5 padding leaves a margin so
    // the polyline isn't flush against the edges, and the max(..., 0.005) floor
    // stops a tiny loop from zooming in absurdly far.
    private var cameraPosition: MapCameraPosition {
        let pts = coords
        guard !pts.isEmpty else { return .automatic }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("RUN COMPLETE")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(hex: "#C6F135"))
                    .kerning(3)
                Text(run.routeName)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                Text(formattedDate(run.date))
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "#888888"))
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 24)

            // Map of the route just run. Only shown when geometry is present:
            // `coords.count > 1` guards against older history entries (saved
            // before waypoints were stored) and degenerate single-point routes.
            // `.allowsHitTesting(false)` makes it a static snapshot — taps and
            // drags pass through instead of letting the user pan/zoom it.
            if coords.count > 1 {
                Map(initialPosition: cameraPosition) {
                    MapPolyline(coordinates: coords)
                        .stroke(Color(hex: "#FF6B35"), lineWidth: 5)
                    if let first = coords.first {
                        Annotation("Start", coordinate: first) {
                            Circle()
                                .fill(Color(hex: "#FF6B35"))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .allowsHitTesting(false)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            // 2×2 stats grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statCard(value: String(format: "%.2f", run.distance), label: "Miles")
                statCard(value: formatTime(run.duration), label: "Time")
                statCard(value: formatPace(run.pace), label: "Pace /mi")
                statCard(value: run.terrain.isEmpty ? "—" : run.terrain.joined(separator: ", "), label: "Terrain")
            }
            .padding(.horizontal, 24)

            Spacer()

            // After a finished run this collapses the entire stack to HomeView in
            // one tap (AppState.popToHome flips the root push flag, which removes
            // every screen above Home). When this screen is opened read-only from
            // Run History, the stack is Home → History → Summary instead, so we
            // just dismiss one level back to the history list — the expected
            // behavior when browsing past runs.
            Button {
                if fromHistory {
                    dismiss()
                } else {
                    AppState.shared.popToHome()
                }
            } label: {
                Text("Back to Home")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color(hex: "#27272D"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "#C6F135"))
                    .cornerRadius(16)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(hex: "#27272D").ignoresSafeArea())
        .navigationBarHidden(true)
        // Display only — the run is now persisted in RunView.handleStop() the moment
        // it ends, so this screen never writes anything (whether reached after a run
        // or opened read-only from Run History).
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Color(hex: "#C6F135"))
                .minimumScaleFactor(0.6)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#888888"))
                .textCase(.uppercase)
                .kerning(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(hex: "#1A1A1A"))
        .cornerRadius(16)
    }

    private func formattedDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: date)
    }

    private func formatTime(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func formatPace(_ p: Double) -> String {
        guard p > 0, p.isFinite, p < 30 else { return "--:--" }
        let m = Int(p)
        let s = Int((p - Double(m)) * 60)
        return String(format: "%d:%02d", m, s)
    }
}

#Preview {
    NavigationStack {
        RunSummaryView(
            run: LocalRun(id: nil, routeName: "Park Loop", distance: 3.12,
                          duration: 1820, pace: 9.71, terrain: ["Parks", "Waterfront"],
                          date: ISO8601DateFormatter().string(from: Date()),
                          // A small square loop so the preview shows the map.
                          waypoints: [
                            Waypoint(latitude: 40.7128, longitude: -74.0060),
                            Waypoint(latitude: 40.7138, longitude: -74.0060),
                            Waypoint(latitude: 40.7138, longitude: -74.0048),
                            Waypoint(latitude: 40.7128, longitude: -74.0048),
                            Waypoint(latitude: 40.7128, longitude: -74.0060),
                          ]),
            fromHistory: false
        )
    }
}
