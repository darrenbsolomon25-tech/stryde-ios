import SwiftUI
import MapKit
import CoreLocation

// Non-observable class holds mutable tracking state that shouldn't trigger
// SwiftUI re-renders on every GPS tick. Only the display values below are @State.
private final class RunRef {
    var lastCoord: CLLocationCoordinate2D
    var lastHeading: Double = 0
    var accumulatedDistance: Double = 0  // miles
    var elapsedSec: Int = 0
    var passedWaypointIndex: Int = 0
    var currentStepIndex: Int = 0
    init(startCoord: CLLocationCoordinate2D) { lastCoord = startCoord }
}

// A triangular chevron marker drawn in SwiftUI — same concept as the
// custom Marker in RunScreen.js that rotates with the runner's heading.
private struct ChevronMarker: View {
    var rotation: Double  // degrees; 0 = pointing up
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "#1E4FCC").opacity(0.25))
                .frame(width: 32, height: 32)
            Triangle()
                .fill(Color(hex: "#1E4FCC"))
                .frame(width: 16, height: 20)
                .rotationEffect(.degrees(rotation))
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

struct RunView: View {
    let route: GeneratedRoute
    let startLocation: CLLocationCoordinate2D

    // These @State values drive the UI and are updated only when they change visually.
    @State private var elapsedTime = 0
    @State private var distanceCovered: Double = 0
    @State private var pace: Double = 0
    @State private var isRunning = true
    @State private var currentStepIndex = 0
    @State private var passedWaypointIndex = 0
    @State private var cameraMode = "follow"
    @State private var heading: Double = 0
    @State private var distanceToNextTurn: Double? = nil
    @State private var currentCoord: CLLocationCoordinate2D
    @State private var cameraPosition: MapCameraPosition

    // Non-UI mutable state lives in this ref to avoid spurious re-renders.
    @State private var ref: RunRef

    @State private var navigateToSummary = false
    @State private var runEnded = false
    @State private var runData: LocalRun? = nil
    @State private var timerTask: Task<Void, Never>? = nil
    @State private var locationTask: Task<Void, Never>? = nil

    init(route: GeneratedRoute, startLocation: CLLocationCoordinate2D) {
        self.route = route
        self.startLocation = startLocation
        _currentCoord = State(initialValue: startLocation)
        _ref = State(initialValue: RunRef(startCoord: startLocation))
        _cameraPosition = State(initialValue: .camera(MapCamera(
            centerCoordinate: startLocation,
            distance: 200, heading: 0, pitch: 65
        )))
    }

    private var nextStep: Step? {
        let nextIdx = currentStepIndex + 1
        guard route.steps.indices.contains(nextIdx) else { return nil }
        return route.steps[nextIdx]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let step = nextStep {
                turnCard(step: step)
            }

            Map(position: $cameraPosition) {
                // Faded completed segment
                if passedWaypointIndex > 0 {
                    let done = Array(route.waypoints[0...passedWaypointIndex])
                        .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    MapPolyline(coordinates: done)
                        .stroke(Color(hex: "#FF6B35").opacity(0.35), lineWidth: 6)
                }
                // Bright remaining segment
                let remaining = Array(route.waypoints[passedWaypointIndex...])
                    .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                if remaining.count > 1 {
                    MapPolyline(coordinates: remaining)
                        .stroke(Color(hex: "#FF6B35"), lineWidth: 6)
                }
                // Start pin
                if let wp = route.waypoints.first {
                    Annotation("Start", coordinate: CLLocationCoordinate2D(latitude: wp.latitude, longitude: wp.longitude)) {
                        Circle().fill(.green).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                // Runner chevron
                Annotation("", coordinate: currentCoord) {
                    ChevronMarker(rotation: cameraMode == "overhead" ? heading : 0)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .overlay(alignment: .topTrailing) {
                Button {
                    cameraMode = cameraMode == "follow" ? "overhead" : "follow"
                    updateCamera(coord: currentCoord, hdg: ref.lastHeading)
                } label: {
                    Text(cameraMode == "follow" ? "Overhead" : "Follow")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(20)
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "#C6F135"), lineWidth: 1))
                }
                .padding(.trailing, 32).padding(.top, 20)
            }

            statsPanel
        }
        .background(Color(hex: "#27272D").ignoresSafeArea())
        // Hide the nav bar during the active run; show it after the run ends
        // so the user can tap back once RunSummaryView is dismissed.
        .navigationBarHidden(!runEnded)
        .navigationDestination(isPresented: $navigateToSummary) {
            if let data = runData { RunSummaryView(run: data, fromHistory: false) }
        }
        .task { startTracking() }
        .onDisappear { stopTracking() }
    }

    // MARK: - Turn card

    private func turnCard(step: Step) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 56, height: 56)
                Text(maneuverArrow(step))
                    .font(.system(size: 28))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let d = distanceToNextTurn {
                    Text(formatTurnDist(d))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                }
                Text(step.instruction)
                    .font(.system(size: 13))
                    .foregroundColor(Color.white.opacity(0.85))
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(hex: "#1E4FCC"))
        .cornerRadius(16)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - Stats panel

    private var statsPanel: some View {
        VStack(spacing: 8) {
            HStack {
                statItem(value: formatTime(elapsedTime), label: "Time")
                Divider().frame(height: 30).background(Color(hex: "#333333"))
                statItem(value: String(format: "%.2f", distanceCovered), label: "Miles")
                Divider().frame(height: 30).background(Color(hex: "#333333"))
                statItem(value: formatPace(pace), label: "Pace /mi")
            }
            .padding(.vertical, 16)
            .background(Color(hex: "#1A1A1A"))
            .cornerRadius(16)

            HStack(spacing: 8) {
                Button {
                    isRunning.toggle()
                    if isRunning { startTimer() } else { timerTask?.cancel() }
                } label: {
                    Text(isRunning ? "Pause" : "Resume")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color(hex: "#1A1A1A"))
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(!isRunning ? Color(hex: "#C6F135") : Color(hex: "#333333"), lineWidth: 1))
                }
                Button { handleStop() } label: {
                    Text("End Run")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color(hex: "#FF3B30"))
                        .cornerRadius(14)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold)).foregroundColor(Color(hex: "#C6F135"))
            Text(label).font(.system(size: 11)).foregroundColor(Color(hex: "#888888"))
                .textCase(.uppercase).kerning(0.5)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tracking

    private func startTracking() {
        startTimer()
        locationTask = Task {
            do {
                let updates = CLLocationUpdate.liveUpdates(.automotiveNavigation)
                for try await update in updates {
                    guard !Task.isCancelled, let loc = update.location else { continue }
                    await MainActor.run { processLocation(loc) }
                }
            } catch {
                print("[RunView] location stream error: \(error)")
            }
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    elapsedTime += 1
                    ref.elapsedSec = elapsedTime
                }
            }
        }
    }

    private func stopTracking() {
        timerTask?.cancel()
        locationTask?.cancel()
    }

    @MainActor
    private func processLocation(_ loc: CLLocation) {
        let coord = loc.coordinate
        let newHeading = loc.course >= 0 ? loc.course : ref.lastHeading

        // Accumulate distance only while running (not paused).
        if isRunning {
            let added = haversineDistanceMiles(
                ref.lastCoord.latitude, ref.lastCoord.longitude,
                coord.latitude, coord.longitude
            )
            ref.accumulatedDistance += added
            distanceCovered = ref.accumulatedDistance

            let minutes = Double(elapsedTime) / 60
            if ref.accumulatedDistance > 0.01 && minutes > 0 {
                pace = minutes / ref.accumulatedDistance
            }
        }

        ref.lastCoord = coord
        ref.lastHeading = newHeading
        currentCoord = coord
        heading = newHeading

        updateCamera(coord: coord, hdg: newHeading)
        updateStep(coord: coord)
        updatePassedWaypoints(coord: coord)
    }

    private func updateCamera(coord: CLLocationCoordinate2D, hdg: Double) {
        if cameraMode == "follow" {
            // Offset the camera center ~60m ahead of the runner so they appear
            // near the bottom of the screen — same Waze-style effect as the RN app.
            let ahead = offsetAhead(lat: coord.latitude, lng: coord.longitude, bearing: hdg, meters: 60)
            cameraPosition = .camera(MapCamera(
                centerCoordinate: ahead, distance: 200, heading: hdg, pitch: 65
            ))
        } else {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: coord, distance: 600, heading: 0, pitch: 0
            ))
        }
    }

    private func updateStep(coord: CLLocationCoordinate2D) {
        let nextIdx = ref.currentStepIndex + 1
        guard route.steps.indices.contains(nextIdx) else { return }
        let next = route.steps[nextIdx]
        let dist = haversineDistanceMiles(
            coord.latitude, coord.longitude,
            next.location.latitude, next.location.longitude
        )
        distanceToNextTurn = dist
        // Advance step when within ~25m of the maneuver point.
        if dist < 0.015 {
            ref.currentStepIndex += 1
            currentStepIndex = ref.currentStepIndex
        }
    }

    private func updatePassedWaypoints(coord: CLLocationCoordinate2D) {
        let end = min(ref.passedWaypointIndex + 20, route.waypoints.count)
        for i in ref.passedWaypointIndex..<end {
            let wp = route.waypoints[i]
            let dist = haversineDistanceMiles(coord.latitude, coord.longitude, wp.latitude, wp.longitude)
            if dist < 0.02 { ref.passedWaypointIndex = i }
        }
        if ref.passedWaypointIndex > passedWaypointIndex {
            passedWaypointIndex = ref.passedWaypointIndex
        }
    }

    private func handleStop() {
        stopTracking()
        runEnded = true
        runData = LocalRun(
            id: nil,
            routeName: route.routeName,
            distance: distanceCovered,
            duration: elapsedTime,
            pace: pace,
            terrain: route.terrain,
            date: ISO8601DateFormatter().string(from: Date())
        )
        navigateToSummary = true
    }

    // MARK: - Helpers

    private func offsetAhead(lat: Double, lng: Double, bearing: Double, meters: Double) -> CLLocationCoordinate2D {
        let R = 6_371_000.0
        let brng = bearing * .pi / 180
        let lat1 = lat * .pi / 180
        let lng1 = lng * .pi / 180
        let d = meters / R
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(brng))
        let lng2 = lng1 + atan2(sin(brng) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lng2 * 180 / .pi)
    }

    private func maneuverArrow(_ step: Step) -> String {
        let m = (step.modifier ?? "").lowercased()
        let t = (step.type ?? "").lowercased()
        if t == "arrive" { return "●" }
        if t == "depart" { return "⬆" }
        if m.contains("uturn") { return "↶" }
        if m == "sharp left" { return "↰" }
        if m == "sharp right" { return "↱" }
        if m.contains("slight left") { return "↖" }
        if m.contains("slight right") { return "↗" }
        if m == "left" { return "⬅" }
        if m == "right" { return "➡" }
        return "⬆"
    }

    private func formatTurnDist(_ miles: Double) -> String {
        let feet = miles * 5280
        if feet < 1000 { return "\(Int(round(feet / 10) * 10)) ft" }
        return String(format: "%.1f mi", miles)
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
        RunView(
            route: GeneratedRoute(routeName: "Test", terrainDescription: "", totalDistance: "3 mi",
                                  estimatedTime: "39 min", waypoints: [], steps: [], terrain: [], requestId: nil),
            startLocation: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        )
    }
}
