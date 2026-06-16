import SwiftUI
import MapKit
import CoreLocation
import QuartzCore  // CACurrentMediaTime() — monotonic clock for the frame loop

// Non-observable class holds mutable tracking state that shouldn't trigger
// SwiftUI re-renders on every GPS tick. Only the display values below are @State.
private final class RunRef {
    var lastCoord: CLLocationCoordinate2D
    var lastHeading: Double = 0
    var accumulatedDistance: Double = 0  // miles
    var elapsedSec: Int = 0
    var passedWaypointIndex: Int = 0
    var currentStepIndex: Int = 0
    var smoothLat: Double = 0
    var smoothLng: Double = 0
    var isFirstLoc: Bool = true
    // Keeps location streaming while the app is backgrounded (screen locked /
    // phone pocketed). Held here so it lives for the whole run and can be
    // invalidated when tracking stops. Requires the `location` UIBackgroundMode.
    var backgroundSession: CLBackgroundActivitySession?

    // Smooth-marker interpolation (Waze-style 60fps glide). GPS fixes arrive ~1Hz;
    // rather than snap the chevron to each fix, we tween it from where it is shown
    // now (`animFrom`) toward the newest projected position (`animTo`) over
    // `animDuration` seconds starting at `animStart`. A frame-rate loop reads these
    // to place the marker in between every frame. Heading tweens the same way.
    var animFrom: CLLocationCoordinate2D
    var animTo: CLLocationCoordinate2D
    var animFromHeading: Double = 0
    var animToHeading: Double = 0
    var animStart: CFTimeInterval = 0
    var animDuration: Double = 1.0
    var lastFixTime: CFTimeInterval = 0

    init(startCoord: CLLocationCoordinate2D) {
        lastCoord = startCoord
        animFrom = startCoord
        animTo = startCoord
    }
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
    @State private var animTask: Task<Void, Never>? = nil  // ~60fps marker glide

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

    // Computed here (not inside Map { }) because @MapContentBuilder only accepts
    // MapContent-returning expressions — let bindings produce () and won't compile.
    // Starts at the live (interpolated) runner position and runs to the finish, so
    // as `currentCoord` advances each frame the line shortens from behind — the
    // traveled path is consumed rather than left as a trail.
    private var remainingCoords: [CLLocationCoordinate2D] {
        let tail: [CLLocationCoordinate2D] = passedWaypointIndex + 1 < route.waypoints.count
            ? Array(route.waypoints[(passedWaypointIndex + 1)...])
                .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            : []
        return [currentCoord] + tail
    }

    var body: some View {
        VStack(spacing: 0) {
            if let step = nextStep {
                turnCard(step: step)
            }

            Map(position: $cameraPosition) {
                // Route ahead only — the path behind the runner is consumed. One
                // polyline from the live runner position to the finish; it visibly
                // shortens from behind as they move, instead of leaving a grey trail.
                if remainingCoords.count > 1 {
                    MapPolyline(coordinates: remainingCoords)
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
                    // Just flip the mode — the per-frame render loop repositions the
                    // camera for the new mode on the next frame (~16ms, effectively instant).
                    cameraMode = cameraMode == "follow" ? "overhead" : "follow"
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
        // Open a background activity session so CLLocationUpdate.liveUpdates keeps
        // delivering fixes after the screen locks or the app backgrounds. Without
        // this (and the `location` UIBackgroundMode declared in the project) the
        // stream pauses the moment the runner pockets the phone, flat-lining the run.
        ref.backgroundSession = CLBackgroundActivitySession()
        startMarkerAnimation()
        locationTask = Task {
            do {
                let updates = CLLocationUpdate.liveUpdates(.fitness)
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
        animTask?.cancel()
        // End the background session so iOS stops the run's background-location
        // activity (and drops the blue status-bar indicator) once the run is over.
        ref.backgroundSession?.invalidate()
        ref.backgroundSession = nil
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

        ref.lastCoord = coord  // raw GPS kept for distance accumulation
        ref.lastHeading = newHeading
        // Note: `heading` (the displayed value) is NOT set here — the render loop
        // tweens it from its current value toward `newHeading` so turns sweep smoothly.

        // Exponential moving average smooths GPS noise so the marker doesn't
        // jitter on every tick. Alpha 0.3 keeps motion responsive at running
        // pace without amplifying satellite-bounce artifacts.
        let alpha = 0.3
        if ref.isFirstLoc {
            ref.smoothLat = coord.latitude
            ref.smoothLng = coord.longitude
            ref.isFirstLoc = false
        } else {
            ref.smoothLat = alpha * coord.latitude + (1 - alpha) * ref.smoothLat
            ref.smoothLng = alpha * coord.longitude + (1 - alpha) * ref.smoothLng
        }
        let smooth = CLLocationCoordinate2D(latitude: ref.smoothLat, longitude: ref.smoothLng)

        // Project the smoothed position onto the nearest route segment so the
        // chevron slides continuously along the polyline instead of jumping
        // between discrete waypoints.
        let (snapIdx, snapped) = nearestRoutePoint(to: smooth)
        if snapIdx > ref.passedWaypointIndex {
            ref.passedWaypointIndex = snapIdx
            passedWaypointIndex = snapIdx
        }

        // Re-target the marker tween instead of snapping currentCoord to the fix.
        // Glide from where the marker is shown right now toward `snapped` over
        // roughly the gap since the last fix; the render loop fills the in-between
        // frames. Clamp the duration so a long gap (e.g. the app was backgrounded)
        // doesn't make the marker crawl, and a burst of fixes doesn't teleport it.
        let now = CACurrentMediaTime()
        let gap = ref.lastFixTime > 0 ? now - ref.lastFixTime : 1.0
        ref.lastFixTime = now
        ref.animFrom = currentCoord
        ref.animTo = snapped
        ref.animFromHeading = heading
        ref.animToHeading = newHeading
        ref.animStart = now
        ref.animDuration = min(max(gap, 0.3), 1.5)

        updateStep(coord: coord)
    }

    // Frame-rate marker glide. GPS fixes land ~1Hz; this loop runs ~60fps and
    // interpolates the chevron (and the camera that follows it) between fixes so
    // motion is continuous instead of a once-per-second hop. A Task.sleep loop
    // mirrors the existing startTimer() pattern — simpler than wiring CADisplayLink
    // into SwiftUI, and the small timing drift is invisible at this scale.
    private func startMarkerAnimation() {
        animTask?.cancel()
        animTask = Task {
            while !Task.isCancelled {
                await MainActor.run { renderFrame() }
                try? await Task.sleep(for: .milliseconds(16))  // ~60fps
            }
        }
    }

    @MainActor
    private func renderFrame() {
        // Progress through the current tween: 0 right after a fix, 1 once the tween
        // duration has elapsed. Clamped, so between fixes the marker rests exactly
        // on the target rather than overshooting past it.
        let elapsed = CACurrentMediaTime() - ref.animStart
        let t = ref.animDuration > 0 ? min(max(elapsed / ref.animDuration, 0), 1) : 1
        currentCoord = lerpCoord(ref.animFrom, ref.animTo, t)
        heading = lerpHeading(ref.animFromHeading, ref.animToHeading, t)
        renderCamera(coord: currentCoord, hdg: heading)
    }

    // Driven every frame off the interpolated marker so the map stays locked to the
    // runner. Set directly with no withAnimation: we're already updating at frame
    // rate, so wrapping each frame in its own animation would fight itself.
    @MainActor
    private func renderCamera(coord: CLLocationCoordinate2D, hdg: Double) {
        if cameraMode == "follow" {
            // Center ~60m ahead of the runner so they sit near the bottom of the
            // screen with the road ahead filling the view — the Waze framing.
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

    // Linear interpolation between two coordinates. Planar lerp in degree space —
    // fine for the few metres a runner covers between frames.
    private func lerpCoord(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    // Interpolate a compass heading along the SHORTEST rotation, so a turn from
    // 350° to 10° sweeps +20° through north instead of unwinding -340° the long way.
    private func lerpHeading(_ from: Double, _ to: Double, _ t: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let h = from + delta * t
        return (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
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

    // Projects `coord` onto each route segment in the lookahead window and
    // returns the segment start index plus the exact projected coordinate.
    // Segment projection (vs. nearest-waypoint) makes the chevron slide
    // continuously along the polyline rather than snapping between points.
    private func nearestRoutePoint(to coord: CLLocationCoordinate2D) -> (index: Int, snapped: CLLocationCoordinate2D) {
        let wps = route.waypoints
        guard wps.count > 1 else {
            let fallback = wps.first.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } ?? coord
            return (0, fallback)
        }
        let searchStart = max(0, ref.passedWaypointIndex - 1)
        let searchEnd = min(wps.count - 2, searchStart + 60)
        var bestIdx = searchStart
        var bestDist = Double.infinity
        var bestSnapped = coord
        for i in searchStart...searchEnd {
            let a = CLLocationCoordinate2D(latitude: wps[i].latitude, longitude: wps[i].longitude)
            let b = CLLocationCoordinate2D(latitude: wps[i + 1].latitude, longitude: wps[i + 1].longitude)
            let (proj, d) = projectOnSegment(coord, from: a, to: b)
            if d < bestDist { bestDist = d; bestIdx = i; bestSnapped = proj }
        }
        return (bestIdx, bestSnapped)
    }

    // Orthogonal projection of p onto segment [a, b]. Uses planar (degree-space)
    // approximation — accurate enough for the short segments in a running route.
    // Returns the projected coordinate and the haversine distance from p to it.
    private func projectOnSegment(
        _ p: CLLocationCoordinate2D,
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> (CLLocationCoordinate2D, Double) {
        let abx = b.longitude - a.longitude, aby = b.latitude - a.latitude
        let ab2 = abx * abx + aby * aby
        guard ab2 > 0 else {
            return (a, haversineDistanceMiles(p.latitude, p.longitude, a.latitude, a.longitude))
        }
        let t = max(0, min(1, ((p.longitude - a.longitude) * abx + (p.latitude - a.latitude) * aby) / ab2))
        let q = CLLocationCoordinate2D(latitude: a.latitude + t * aby, longitude: a.longitude + t * abx)
        return (q, haversineDistanceMiles(p.latitude, p.longitude, q.latitude, q.longitude))
    }

    private func handleStop() {
        stopTracking()
        runEnded = true
        let finished = LocalRun(
            id: nil,
            routeName: route.routeName,
            distance: distanceCovered,
            duration: elapsedTime,
            pace: pace,
            terrain: route.terrain,
            date: ISO8601DateFormatter().string(from: Date())
        )
        // Persist the instant the run ends — not as a side effect of the summary
        // screen appearing. Decoupling the save from view lifecycle means a run is
        // never lost if RunSummaryView's .task doesn't fire for any reason.
        AppState.shared.addLocalRun(finished)
        runData = finished
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
