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
    // Reported horizontal accuracy of the latest fix, in FEET. The start gate
    // widens to this when GPS is loose so a ±60 ft fix doesn't demand the runner
    // stand on an exact point they can't actually reach.
    var lastAccuracyFeet: Double = 0

    init(startCoord: CLLocationCoordinate2D, startHeading: Double = 0) {
        lastCoord = startCoord
        animFrom = startCoord
        animTo = startCoord
        lastHeading = startHeading
        animFromHeading = startHeading
        animToHeading = startHeading
    }
}

// A triangular chevron marker drawn in SwiftUI. Its rotation is driven by the
// ROUTE's direction at the runner's position (not the phone's compass / GPS
// course), so the arrow always faces the way the path goes.
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

    // Run lifecycle phase. The run opens in `.approachingStart`: the runner is usually
    // 20-30 ft from the route's first waypoint (the loop snaps to the nearest path),
    // so the timer and distance stay frozen at zero while they walk to the line.
    // Reaching the start unlocks the Start button; tapping it runs a 5-sec countdown
    // and flips to `.running`, where normal tracking takes over.
    private enum RunPhase: Equatable { case approachingStart, running }
    @State private var phase: RunPhase = .approachingStart
    @State private var distanceToStartFeet: Double? = nil
    @State private var countdown: Int? = nil          // 5…1 during the pre-run countdown
    @State private var countdownTask: Task<Void, Never>? = nil
    // Base unlock radius for the start gate. 10 ft was too tight to ever trip on real
    // hardware (consumer GPS is rarely better than ~16 ft, worse among buildings), so
    // the gate now opens at 50 ft OR the live GPS accuracy, whichever is larger — see
    // `isAtStart`. The runner only has to be "basically on the line," not standing on
    // an exact pixel they can't physically find.
    private let unlockRadiusFeet: Double = 50

    // Finish detection. Once the runner has actually covered the loop and comes back
    // within this radius of the final waypoint, a "you're done" prompt auto-appears
    // (handled in `processLocation`). 25 ft is loose enough to trip reliably without
    // firing the moment they leave, since the start and finish of a loop nearly coincide.
    private let finishRadiusFeet: Double = 25
    @State private var showFinishPrompt = false
    // Latched true if the runner taps "Keep running" on the finish prompt, so it won't
    // nag them again on later laps — they end manually with the End Run button.
    @State private var finishPromptDismissed = false

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
        // Orient everything to the route's opening direction from frame one, so the
        // camera (and the arrow) start facing down the path instead of north and then
        // swinging around on the first GPS fix.
        let initialHeading: Double = route.waypoints.count > 1
            ? bearingDegrees(route.waypoints[0].latitude, route.waypoints[0].longitude,
                             route.waypoints[1].latitude, route.waypoints[1].longitude)
            : 0
        _currentCoord = State(initialValue: startLocation)
        _heading = State(initialValue: initialHeading)
        _ref = State(initialValue: RunRef(startCoord: startLocation, startHeading: initialHeading))
        _cameraPosition = State(initialValue: .camera(MapCamera(
            centerCoordinate: startLocation,
            distance: 200, heading: initialHeading, pitch: 65
        )))
    }

    // Run vs walk, carried by the route. Drives the on-screen wording ("Start
    // Walk", "End Walk") and is stamped onto the saved LocalRun in handleStop().
    private var activity: ActivityKind { route.activity }

    private var nextStep: Step? {
        let nextIdx = currentStepIndex + 1
        guard route.steps.indices.contains(nextIdx) else { return nil }
        return route.steps[nextIdx]
    }

    // The point the runner must reach before the run can begin: the route's first
    // waypoint. Falls back to the passed-in start coordinate if a route somehow has
    // no waypoints, so the gate just unlocks immediately rather than misbehaving.
    private var startCoord: CLLocationCoordinate2D {
        if let w = route.waypoints.first {
            return CLLocationCoordinate2D(latitude: w.latitude, longitude: w.longitude)
        }
        return startLocation
    }

    // True once the runner is within the unlock radius of the start. The effective
    // radius is the larger of our base radius and the phone's own reported accuracy:
    // if GPS only knows the position to ±70 ft, demanding the runner be within 50 ft is
    // physically impossible, so the gate widens to match what the hardware can resolve.
    private var isAtStart: Bool {
        guard let d = distanceToStartFeet else { return false }
        return d <= max(unlockRadiusFeet, ref.lastAccuracyFeet)
    }

    // Computed here (not inside Map { }) because @MapContentBuilder only accepts
    // MapContent-returning expressions — let bindings produce () and won't compile.
    // Starts at the live (interpolated) runner position and runs to the finish, so
    // as `currentCoord` advances each frame the line shortens from behind — the
    // traveled path is consumed rather than left as a trail.
    private var remainingCoords: [CLLocationCoordinate2D] {
        // Before the run starts, show the whole planned loop so the runner sees what
        // they're about to run while walking to the line. Once running, the line is
        // consumed from behind (live position → finish).
        if phase == .approachingStart {
            return route.waypoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        let tail: [CLLocationCoordinate2D] = passedWaypointIndex + 1 < route.waypoints.count
            ? Array(route.waypoints[(passedWaypointIndex + 1)...])
                .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            : []
        return [currentCoord] + tail
    }

    var body: some View {
        VStack(spacing: 0) {
            if phase == .approachingStart {
                walkToStartCard
            } else if let step = nextStep {
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
        // While approaching the start the nav bar stays visible so the runner can
        // back out to the preview. It hides once the run is live, then reappears
        // after the run ends so they can tap back once RunSummaryView is dismissed.
        .navigationBarHidden(phase == .running && !runEnded)
        .navigationDestination(isPresented: $navigateToSummary) {
            if let data = runData { RunSummaryView(run: data, fromHistory: false) }
        }
        // The pre-run countdown sits on top of everything until it flips to .running.
        .overlay {
            if let value = countdown { countdownOverlay(value) }
        }
        // The auto-finish prompt sits on top once the runner loops back to the finish.
        .overlay {
            if showFinishPrompt { finishPromptOverlay }
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

    // MARK: - Walk-to-start (pre-run)

    // Shown in place of the turn card while the runner walks to the start line. Same
    // blue card shape as a real maneuver, but the "instruction" is to reach the start
    // and the big number is the live distance left to it.
    private var walkToStartCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 56, height: 56)
                Image(systemName: "figure.walk")
                    .font(.system(size: 26))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(startDistanceText)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("Walk to your start point")
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

    private var startDistanceText: String {
        guard let d = distanceToStartFeet else { return "Locating…" }
        if isAtStart { return "You're at the start" }
        return "\(Int(d.rounded())) ft to start"
    }

    // Bottom controls during the approach phase: a primary button locked until the
    // runner reaches the start, plus a muted bypass so a bad GPS fix can't trap them
    // here. Both routes lead through the countdown into the live run.
    private var approachControls: some View {
        VStack(spacing: 8) {
            Button {
                if isAtStart { beginRun() }
            } label: {
                Text(isAtStart ? "Start \(activity.noun)" : "Walk to the start to unlock")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isAtStart ? Color(hex: "#27272D") : Color(hex: "#888888"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(isAtStart ? Color(hex: "#C6F135") : Color(hex: "#1A1A1A"))
                    .cornerRadius(14)
            }
            .disabled(!isAtStart)

            Button { beginRun() } label: {
                Text("GPS off? Start anyway")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#888888"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
        }
    }

    // Full-screen countdown shown after the runner commits, before tracking begins.
    private func countdownOverlay(_ value: Int) -> some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Starting in")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Color(hex: "#888888"))
                // `.id(value)` gives each number its own identity so 5→4→3 is a
                // replace (the transition re-fires) rather than one label editing text.
                Text("\(value)")
                    .font(.system(size: 120, weight: .bold))
                    .foregroundColor(Color(hex: "#C6F135"))
                    .id(value)
                    .transition(.scale.combined(with: .opacity))
                Button {
                    countdownTask?.cancel()
                    countdown = nil
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(Color(hex: "#1A1A1A"))
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(hex: "#333333"), lineWidth: 1))
                }
                .padding(.top, 12)
            }
        }
        .animation(.easeOut(duration: 0.25), value: value)
    }

    // Auto-presented when the runner returns to the finish. End Run is the prominent
    // default (this is "it ends for you"); Keep Running is the escape hatch for anyone
    // doing extra laps or a cool-down. Keep Running latches `finishPromptDismissed` so
    // it won't pop again — they finish on the manual End Run button from there.
    private var finishPromptOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 56))
                    .foregroundColor(Color(hex: "#C6F135"))
                Text("You're back at the finish")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("Nice work. End the \(activity.noun.lowercased()), or keep going if you're adding laps.")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "#888888"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button { handleStop() } label: {
                    Text("End \(activity.noun)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: "#27272D"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "#C6F135"))
                        .cornerRadius(14)
                }
                Button {
                    finishPromptDismissed = true
                    showFinishPrompt = false
                } label: {
                    Text("Keep running")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(hex: "#1A1A1A"))
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(hex: "#333333"), lineWidth: 1))
                }
            }
            .padding(.horizontal, 40)
        }
        .transition(.opacity)
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

            if phase == .approachingStart {
                approachControls
            } else {
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
                        Text("End \(activity.noun)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color(hex: "#FF3B30"))
                            .cornerRadius(14)
                    }
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
        // NOTE: the run timer is NOT started here. The run opens in `.approachingStart`,
        // so time/distance must stay frozen until `beginRun()` flips to `.running`.
        // Location streaming + the marker glide DO start now, so we can track the
        // runner walking to the start and detect when they've arrived.
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
        countdownTask?.cancel()
        // End the background session so iOS stops the run's background-location
        // activity (and drops the blue status-bar indicator) once the run is over.
        ref.backgroundSession?.invalidate()
        ref.backgroundSession = nil
    }

    @MainActor
    private func processLocation(_ loc: CLLocation) {
        let coord = loc.coordinate

        // Track GPS accuracy (Core Location reports it in metres; negative = invalid)
        // so the start gate can widen on a loose fix. ×3.28084 converts metres → feet.
        if loc.horizontalAccuracy > 0 {
            ref.lastAccuracyFeet = loc.horizontalAccuracy * 3.28084
        }

        // Approaching-start phase: freeze time/distance, don't snap to the route or
        // advance steps. Track the runner's real position, measure how far they still
        // are from the start, and aim the chevron (and follow-camera) straight at the
        // start so it reads as a "walk this way" arrow.
        if phase == .approachingStart {
            ref.lastCoord = coord  // keep current so the first running fix adds ~0
            updateSmoothed(coord)
            let smooth = CLLocationCoordinate2D(latitude: ref.smoothLat, longitude: ref.smoothLng)
            let target = startCoord
            distanceToStartFeet = haversineDistanceMiles(
                smooth.latitude, smooth.longitude, target.latitude, target.longitude
            ) * 5280
            let hdg = bearingDegrees(smooth.latitude, smooth.longitude, target.latitude, target.longitude)
            ref.lastHeading = hdg
            retargetMarker(to: smooth, heading: hdg)
            return
        }

        // --- Running phase ---

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

        updateSmoothed(coord)
        let smooth = CLLocationCoordinate2D(latitude: ref.smoothLat, longitude: ref.smoothLng)

        // Project the smoothed position onto the nearest route segment so the
        // chevron slides continuously along the polyline instead of jumping
        // between discrete waypoints.
        let (snapIdx, snapped) = nearestRoutePoint(to: smooth)
        if snapIdx > ref.passedWaypointIndex {
            ref.passedWaypointIndex = snapIdx
            passedWaypointIndex = snapIdx
        }

        // Heading comes from the ROUTE's direction at the snapped position — not from
        // `loc.course`. The arrow and the follow-camera face the way the path goes, so
        // the marker stays locked to the route no matter which way the phone points or
        // how the GPS course jitters. (`heading` itself is set by the render loop, which
        // tweens from its current value toward this target so turns sweep smoothly.)
        let routeHdg = routeHeading(fromIndex: snapIdx, at: snapped) ?? ref.lastHeading
        ref.lastHeading = routeHdg

        retargetMarker(to: snapped, heading: routeHdg)
        updateStep(coord: coord)
        checkFinish(smooth)
    }

    // Auto-finish: once the runner has looped back to the final waypoint, surface a
    // prompt that ends the run for them (they can override with "Keep running"). We
    // only arm it after they've covered most of the loop — a loop's finish sits almost
    // on top of its start, so without the coverage guard this would fire at second one.
    @MainActor
    private func checkFinish(_ pos: CLLocationCoordinate2D) {
        guard !showFinishPrompt, !finishPromptDismissed, !runEnded else { return }
        guard let last = route.waypoints.last else { return }
        let lastIdx = route.waypoints.count - 1
        guard lastIdx > 0,
              Double(ref.passedWaypointIndex) >= Double(lastIdx) * 0.85 else { return }
        let feetToFinish = haversineDistanceMiles(
            pos.latitude, pos.longitude, last.latitude, last.longitude
        ) * 5280
        if feetToFinish <= finishRadiusFeet {
            showFinishPrompt = true
        }
    }

    // Exponential moving average over raw GPS, shared by both phases. Alpha 0.3 keeps
    // motion responsive at running pace without amplifying satellite-bounce jitter.
    @MainActor
    private func updateSmoothed(_ coord: CLLocationCoordinate2D) {
        let alpha = 0.3
        if ref.isFirstLoc {
            ref.smoothLat = coord.latitude
            ref.smoothLng = coord.longitude
            ref.isFirstLoc = false
        } else {
            ref.smoothLat = alpha * coord.latitude + (1 - alpha) * ref.smoothLat
            ref.smoothLng = alpha * coord.longitude + (1 - alpha) * ref.smoothLng
        }
    }

    // Re-aim the marker glide: tween from where the marker shows now toward `target`
    // (and `hdg`) over roughly the gap since the last fix, clamped so a long gap
    // doesn't crawl and a burst of fixes doesn't teleport. The render loop fills frames.
    @MainActor
    private func retargetMarker(to target: CLLocationCoordinate2D, heading hdg: Double) {
        let now = CACurrentMediaTime()
        let gap = ref.lastFixTime > 0 ? now - ref.lastFixTime : 1.0
        ref.lastFixTime = now
        ref.animFrom = currentCoord
        ref.animTo = target
        ref.animFromHeading = heading
        ref.animToHeading = hdg
        ref.animStart = now
        ref.animDuration = min(max(gap, 0.3), 1.5)
    }

    // MARK: - Starting the run

    // Called when the runner taps Start (or the bypass). Runs a 5→1 countdown, then
    // flips to the running phase. Cancelable via the overlay's Cancel button. The
    // `countdown == nil` guard stops a double-tap from spawning a second countdown.
    private func beginRun() {
        guard phase == .approachingStart, countdown == nil else { return }
        countdownTask?.cancel()
        countdownTask = Task {
            for n in stride(from: 5, through: 1, by: -1) {
                await MainActor.run { countdown = n }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            await MainActor.run { startRunningPhase() }
        }
    }

    @MainActor
    private func startRunningPhase() {
        countdown = nil
        phase = .running
        // Anchor distance at the runner's current position so the walk-to-start leg
        // isn't counted, and zero the clock/odometer the live run starts from.
        ref.lastCoord = currentCoord
        ref.accumulatedDistance = 0
        distanceCovered = 0
        ref.passedWaypointIndex = 0
        passedWaypointIndex = 0
        ref.lastFixTime = 0
        elapsedTime = 0
        ref.elapsedSec = 0
        startTimer()
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

    // The direction the route itself runs at the runner's current position, taken
    // purely from the route polyline — never from GPS course or the compass. We walk
    // a short distance ahead along the path (past dense, individually-jittery
    // waypoints) and return the bearing toward that look-ahead point, so the arrow
    // points the way the route goes next rather than wherever the phone happens to be
    // moving. `idx` is the segment the runner is snapped onto; `at` is the snapped
    // point. Returns nil only once there's no path left ahead (caller keeps the last
    // heading).
    private func routeHeading(fromIndex idx: Int, at snapped: CLLocationCoordinate2D) -> Double? {
        let wps = route.waypoints
        guard wps.count > 1 else { return nil }
        let lookaheadMeters = 20.0
        var accumulated = 0.0
        var prev = snapped
        var i = idx + 1
        while i < wps.count {
            let pt = CLLocationCoordinate2D(latitude: wps[i].latitude, longitude: wps[i].longitude)
            // haversineDistanceMiles → meters (×1609.34) to accumulate the look-ahead.
            accumulated += haversineDistanceMiles(prev.latitude, prev.longitude, pt.latitude, pt.longitude) * 1609.34
            if accumulated >= lookaheadMeters {
                return bearingDegrees(snapped.latitude, snapped.longitude, pt.latitude, pt.longitude)
            }
            prev = pt
            i += 1
        }
        // Within the look-ahead window of the finish: aim straight at the last waypoint.
        guard let last = wps.last,
              last.latitude != snapped.latitude || last.longitude != snapped.longitude else { return nil }
        return bearingDegrees(snapped.latitude, snapped.longitude, last.latitude, last.longitude)
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
        // Idempotency guard: "End Run" has no disabled state, so a fast double-tap
        // (likely on a real device before the summary push covers this screen) would
        // otherwise call addLocalRun twice and save the run twice. `runEnded` is the
        // latch — set below and never reset, so the second tap returns immediately.
        guard !runEnded else { return }
        stopTracking()
        runEnded = true
        // Save only the part of the loop actually covered, not the whole planned
        // route. `ref.passedWaypointIndex` is the furthest waypoint the runner reached
        // — it only ever advances forward (set in processLocation) — so taking the
        // first `index + 1` waypoints is the path from the start through that point.
        // Run half the loop → half is stored → the summary map draws half. `prefix`
        // clamps to the array length, so an over-count can never index out of bounds.
        let coveredWaypoints = Array(route.waypoints.prefix(ref.passedWaypointIndex + 1))
        let finished = LocalRun(
            id: nil,
            routeName: route.routeName,
            distance: distanceCovered,
            duration: elapsedTime,
            pace: pace,
            terrain: route.terrain,
            date: ISO8601DateFormatter().string(from: Date()),
            // The covered portion of the planned route, so RunSummaryView (and Run
            // History later) draws how far along the loop the runner actually got.
            waypoints: coveredWaypoints,
            // Stamp run vs walk onto the saved record so history can show which
            // is which and stats can be split later.
            activity: route.activity
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
