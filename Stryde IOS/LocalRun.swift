import Foundation

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

// Cardinal bearing from point A to point B — used to tell the runner
// which direction to walk to reach a suggested start point.
func bearingCardinal(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> String {
    let dLon = (lon2 - lon1) * .pi / 180
    let y = sin(dLon) * cos(lat2 * .pi / 180)
    let x = cos(lat1 * .pi / 180) * sin(lat2 * .pi / 180)
        - sin(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * cos(dLon)
    var bearing = atan2(y, x) * 180 / .pi
    if bearing < 0 { bearing += 360 }
    let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW", "N"]
    return dirs[Int((bearing + 22.5) / 45) % 8]
}
