import Foundation

// ActivityKind is whether a route is a run or a walk.
//
// `enum ... : String` means each case has a matching text value (`.run`
// ⇄ "run"), so `Codable` can save/load it as a plain string in JSON and we can
// send `.rawValue` to the backend. The two computed properties (`noun`,
// `symbol`) are just convenience: a computed `var` runs its code each time it's
// read — it stores nothing — so views can write `activity.noun` instead of
// repeating the same `if` everywhere.
enum ActivityKind: String, Codable {
    case run
    case walk

    // Capitalized noun for on-screen copy: "Run" / "Walk".
    var noun: String { self == .walk ? "Walk" : "Run" }
    // SF Symbol name for the history list + toggles.
    var symbol: String { self == .walk ? "figure.walk" : "figure.run" }
}

// LocalRun is the shape we save on-device for run history.
// It mirrors the JS `runData` object from RunScreen.js.
// Distances are in miles and duration is in seconds — same as the RN app.
struct LocalRun: Codable, Identifiable {
    var id: String?
    var routeName: String
    var distance: Double   // miles
    var duration: Int      // seconds
    var pace: Double       // min/mile
    var terrain: [String]
    var date: String       // ISO-8601

    // The planned loop the run followed, saved so the summary screen can draw it.
    // Optional with a `nil` default for two reasons: (1) runs saved before this
    // field existed have no `waypoints` key in UserDefaults, and an optional
    // decodes a missing key as `nil` instead of throwing; (2) the default makes
    // the synthesized memberwise initializer treat it as optional, so existing
    // `LocalRun(...)` call sites that don't pass it still compile unchanged.
    var waypoints: [Waypoint]? = nil

    // Whether this was a run or a walk. Optional with a nil default for the same
    // reason as `waypoints` above: runs saved before this field existed have no
    // `activity` key in UserDefaults, and an Optional decodes a missing key as
    // nil instead of throwing. The default also keeps the synthesized memberwise
    // initializer happy, so existing `LocalRun(...)` call sites still compile.
    var activity: ActivityKind? = nil

    // Non-optional accessor for views: legacy/nil records read as `.run`.
    var activityKind: ActivityKind { activity ?? .run }

    // Converts to the backend Run shape (km, startedAt/endedAt) for postRun().
    func toBackendRun() -> Run {
        let start = date
        let endDate = ISO8601DateFormatter().date(from: date)
            .map { $0.addingTimeInterval(Double(duration)) }
        let end = endDate.flatMap { ISO8601DateFormatter().string(from: $0) }
        return Run(
            id: id,
            startedAt: start,
            endedAt: end,
            durationS: Double(duration),
            distanceKm: distance * 1.60934,
            routeType: "loop",
            routeName: routeName,
            waypoints: [],
            steps: []
        )
    }
}

// Haversine formula: straight-line distance in miles between two lat/lng points.
// Used by RunView to accumulate distance as the runner moves.
func haversineDistanceMiles(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let R = 3958.8
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
        + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
        * sin(dLon / 2) * sin(dLon / 2)
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))
}

// Parses "3 mi", "3.5 mi", or bare "3.5" into a Double of miles.
func parseMiles(_ s: String) -> Double {
    Double(s.replacingOccurrences(of: " mi", with: "").trimmingCharacters(in: .whitespaces)) ?? 3.0
}

// Converts a display distance string into miles, honoring the activity's unit.
// Runs are entered in miles ("3 mi"); walks are entered as minutes ("30 min")
// and converted at a steady ~3 mph (20 min/mile). The backend always works in
// distance, so this is where "minutes" becomes a target distance for a walk.
func milesFromDisplay(_ s: String, activity: ActivityKind) -> Double {
    guard activity == .walk else { return parseMiles(s) }
    let cleaned = s.lowercased()
        .replacingOccurrences(of: "min", with: "")
        .trimmingCharacters(in: .whitespaces)
    let minutes = Double(cleaned) ?? 30
    return minutes / 20.0
}

// Compass bearing in degrees (0–360, 0 = north) from point A to point B.
// Shared by the cardinal helper below and by RunView, which uses it to point the
// runner's arrow along the route instead of along the noisy GPS course.
func bearingDegrees(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let dLon = (lon2 - lon1) * .pi / 180
    let y = sin(dLon) * cos(lat2 * .pi / 180)
    let x = cos(lat1 * .pi / 180) * sin(lat2 * .pi / 180)
        - sin(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * cos(dLon)
    let bearing = atan2(y, x) * 180 / .pi
    return (bearing + 360).truncatingRemainder(dividingBy: 360)
}

// Cardinal bearing from point A to point B — used to tell the runner
// which direction to walk to reach a suggested start point.
func bearingCardinal(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> String {
    let bearing = bearingDegrees(lat1, lon1, lat2, lon2)
    let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW", "N"]
    return dirs[Int((bearing + 22.5) / 45) % 8]
}
