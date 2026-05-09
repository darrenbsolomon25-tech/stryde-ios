import Foundation

// MARK: - Response Models
// These structs mirror the JSON shapes the backend sends back.
// "Codable" means Swift can automatically decode JSON into them.

struct UserProfile: Codable {
    // Sent to backend
    var fitnessLevel: String? = nil
    var terrain: [String]? = nil
    var preferredDistance: String? = nil
    var goals: [String]? = nil
    // Stored locally only (PII — never sent to backend)
    var phone: String? = nil
    var age: String? = nil
    var gender: String? = nil
}

struct Run: Codable, Identifiable {
    var id: String?
    var startedAt: String
    var endedAt: String?
    var durationS: Double?
    var distanceKm: Double?
    var routeType: String?
    var routeName: String?
    var waypoints: [Waypoint]
    var steps: [Step]
}

struct Waypoint: Codable {
    var latitude: Double
    var longitude: Double

    // Backend sends { lat, lng } — we map them to latitude/longitude here
    enum CodingKeys: String, CodingKey {
        case latitude = "lat"
        case longitude = "lng"
    }
}

struct Step: Codable {
    var instruction: String
    var type: String?
    var modifier: String?
    var distanceMeters: Double?
    var location: Waypoint
    var name: String?
}

struct GeneratedRoute {
    var routeName: String
    var terrainDescription: String
    var totalDistance: String
    var estimatedTime: String
    var waypoints: [Waypoint]
    var steps: [Step]
    var terrain: [String]
    var requestId: String?
}

struct SuggestedStart: Codable {
    var lat: Double
    var lng: Double
    var walkMeters: Double
    var direction: String
}

// generateRoute() returns either a route or a suggested start location
enum RouteResult {
    case route(GeneratedRoute)
    case suggestedStart(SuggestedStart)
}

// Parameters used to regenerate a route from RoutePreviewView.
// Mirrors the genParams object passed through React Navigation in the RN app.
struct GenParams {
    var profile: UserProfile?
    var distance: String
    var customRequest: String?
    var routeType: String
}

// MARK: - APIService

class APIService {
    // Singleton — same pattern as api.js being a module-level object
    static let shared = APIService()
    private init() {}

    private let baseURL = "https://stryde-route-service-production.up.railway.app"

    // Clerk wires this in after sign-in (same as setTokenGetter in api.js)
    var tokenGetter: (() async -> String?)? = nil

    // Clerk wires this in to handle 401s (same as setAuthErrorHandler in api.js)
    var onAuthError: (() -> Void)? = nil

    // MARK: - Core fetch helper (mirrors jsonFetch in api.js)

    private func jsonFetch<T: Decodable>(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Attach JWT if we have a token getter wired in
        if let token = await tokenGetter?() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if http.statusCode == 401 {
            // Fire sign-out callback, same as api.js _onAuthError?.()
            onAuthError?()
            throw NSError(domain: "APIService", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Your session has expired. Please sign in again."])
        }

        guard (200...299).contains(http.statusCode) else {
            // Try to pull reason/error from the JSON body
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let reason = json?["reason"] as? String ?? json?["error"] as? String ?? ""
            throw NSError(domain: "APIService", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "\(http.statusCode)\(reason.isEmpty ? "" : " — \(reason)")"])
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Endpoints (mirrors api.js exports)

    func touchUser() async throws {
        // void response — we use [String: String] as a throwaway decode target
        let _: [String: String] = try await jsonFetch(path: "/users/touch", method: "POST")
    }

    func linkDevice(deviceId: String) async throws {
        let _: [String: String] = try await jsonFetch(
            path: "/users/link-device",
            method: "POST",
            body: ["deviceId": deviceId]
        )
    }

    func getProfile() async throws -> UserProfile {
        struct Wrapper: Decodable { var profile: UserProfile }
        let wrapper: Wrapper = try await jsonFetch(path: "/profile/me")
        return wrapper.profile
    }

    func putProfile(_ prefs: UserProfile) async throws -> UserProfile {
        let body: [String: Any] = [
            "fitnessLevel": prefs.fitnessLevel as Any,
            "terrain": prefs.terrain ?? [],
            "preferredDistance": prefs.preferredDistance as Any,
            "goals": prefs.goals ?? []
        ]
        struct Wrapper: Decodable { var profile: UserProfile }
        let wrapper: Wrapper = try await jsonFetch(path: "/profile/me", method: "PUT", body: body)
        return wrapper.profile
    }

    func postRun(_ run: Run) async throws -> Run {
        let body: [String: Any] = [
            "startedAt": run.startedAt,
            "endedAt": run.endedAt as Any,
            "durationS": run.durationS as Any,
            "distanceKm": run.distanceKm as Any,
            "routeType": run.routeType as Any,
            "routeName": run.routeName as Any,
            "waypoints": run.waypoints.map { ["lat": $0.latitude, "lng": $0.longitude] },
            "steps": []
        ]
        struct Wrapper: Decodable { var run: Run }
        let wrapper: Wrapper = try await jsonFetch(path: "/runs", method: "POST", body: body)
        return wrapper.run
    }

    func getRuns() async throws -> [Run] {
        struct Wrapper: Decodable { var runs: [Run] }
        let wrapper: Wrapper = try await jsonFetch(path: "/runs/me")
        return wrapper.runs
    }

    func deleteRun(id: String) async throws {
        let _: [String: String] = try await jsonFetch(path: "/runs/\(id)", method: "DELETE")
    }

    func generateRoute(
        profile: UserProfile?,
        latitude: Double,
        longitude: Double,
        distanceMiles: Double,
        customRequest: String? = nil,
        routeType: String = "loop"
    ) async throws -> RouteResult {
        let distanceKm = distanceMiles * 1.60934

        var profileBody: [String: Any]? = nil
        if let p = profile {
            profileBody = [
                "fitnessLevel": p.fitnessLevel as Any,
                "terrain": p.terrain ?? [],
                "preferredDistance": p.preferredDistance as Any,
                "goals": p.goals as Any
            ]
        }

        var body: [String: Any] = [
            "lat": latitude,
            "lng": longitude,
            "distanceKm": distanceKm,
            "routeType": routeType
        ]
        if let cr = customRequest { body["customRequest"] = cr }
        if let pb = profileBody { body["profile"] = pb }

        // Raw decode so we can check for suggestedStart before parsing the route
        struct RawResponse: Decodable {
            var name: String?
            var waypoints: [[String: Double]]?
            var steps: [RawStep]?
            var requestId: String?
            var suggestedStart: SuggestedStart?
        }
        struct RawStep: Decodable {
            var instruction: String
            var type: String?
            var modifier: String?
            var distanceMeters: Double?
            var location: [String: Double]
            var name: String?
        }

        let raw: RawResponse = try await jsonFetch(path: "/generate-route", method: "POST", body: body)

        if let suggested = raw.suggestedStart {
            return .suggestedStart(suggested)
        }

        let fitnessLevel = profile?.fitnessLevel ?? "Beginner"
        let pace = fitnessLevel == "Advanced" ? 8.0 : fitnessLevel == "Intermediate" ? 10.0 : 13.0
        let estimatedMinutes = Int(distanceMiles * pace)

        let waypoints = (raw.waypoints ?? []).map {
            Waypoint(latitude: $0["lat"] ?? 0, longitude: $0["lng"] ?? 0)
        }
        let steps = (raw.steps ?? []).map { s in
            Step(
                instruction: s.instruction,
                type: s.type,
                modifier: s.modifier,
                distanceMeters: s.distanceMeters,
                location: Waypoint(latitude: s.location["lat"] ?? 0, longitude: s.location["lng"] ?? 0),
                name: s.name
            )
        }

        let route = GeneratedRoute(
            routeName: raw.name ?? "Your Route",
            terrainDescription: "A \(String(format: "%.1f", distanceMiles))-mile loop near you.",
            totalDistance: "\(String(format: "%.1f", distanceMiles)) miles",
            estimatedTime: "\(estimatedMinutes) minutes",
            waypoints: waypoints,
            steps: steps,
            terrain: profile?.terrain ?? [],
            requestId: raw.requestId
        )
        return .route(route)
    }

    func deleteAccount() async throws {
        let _: [String: String] = try await jsonFetch(path: "/users/me", method: "DELETE")
    }

    func postRouteFeedback(requestId: String?, event: String) async throws {
        guard let id = requestId else { return }
        let _: [String: String] = try await jsonFetch(
            path: "/route-feedback",
            method: "POST",
            body: ["requestId": id, "event": event]
        )
    }
}
