import Foundation
import ClerkKit

// @Observable replaces ObservableObject — any view that reads a property here
// will automatically re-render when that property changes. No @Published needed.
@Observable
@MainActor
class AppState {
    static let shared = AppState()
    private init() {}

    // These three drive what ContentView renders, same as the flags in AppNavigator.js
    var bootDone = false
    var hasProfile = false

    // Controls the slide-in drawer (hamburger menu)
    var drawerOpen = false

    // Programmatic navigation flags set by DrawerView.
    // HomeView watches these to push screens onto the NavigationStack.
    var showRunHistory = false
    var showSettings = false

    // Local copies of the user's data — populated during boot
    var userProfile: UserProfile? = nil
    var runs: [Run] = []

    // Local run history (miles + pace shape, not the backend km shape)
    var localRuns: [LocalRun] = []

    // MARK: - Boot sequence (mirrors AppNavigator.js steps 3-8)

    func boot() async {
        // Step 1: wire Clerk's token getter into APIService so every request
        // gets an Authorization: Bearer header — same as setTokenGetter in api.js
        APIService.shared.tokenGetter = {
            try? await Clerk.shared.auth.getToken()
        }

        // Step 2: wire sign-out callback for 401 responses — same as setAuthErrorHandler
        APIService.shared.onAuthError = {
            Task { try? await Clerk.shared.auth.signOut() }
        }

        // Steps 3-5: touch user, sync profile, sync runs
        // Each is fire-and-continue — a failure doesn't block the rest of boot
        await touchUser()
        await syncProfile()
        await syncRuns()

        // Load local run history (stored in miles/pace shape, separate from backend runs)
        localRuns = loadLocalRuns()

        // Step 6: decide whether to show Onboarding or Home
        hasProfile = userProfile != nil
        bootDone = true
    }

    private func touchUser() async {
        do {
            try await APIService.shared.touchUser()
        } catch {
            print("[AppState] touchUser failed: \(error.localizedDescription)")
        }
    }

    private func syncProfile() async {
        do {
            let profile = try await APIService.shared.getProfile()
            userProfile = profile
            saveProfile(profile)
        } catch {
            // Fall back to whatever UserDefaults already has
            userProfile = loadProfile()
            print("[AppState] syncProfile failed, using local: \(error.localizedDescription)")
        }
    }

    private func syncRuns() async {
        do {
            let backendRuns = try await APIService.shared.getRuns()
            runs = backendRuns
            saveRuns(backendRuns)
        } catch {
            runs = loadRuns()
            print("[AppState] syncRuns failed, using local: \(error.localizedDescription)")
        }
    }

    // MARK: - UserDefaults persistence (replaces AsyncStorage)
    // UserDefaults stores simple key-value data. For structs we encode to JSON first.

    private let profileKey = "userProfile"
    private let runsKey = "runHistory"
    private let localRunsKey = "localRunHistory"

    func saveProfile(_ profile: UserProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
    }

    func loadProfile() -> UserProfile? {
        guard let data = UserDefaults.standard.data(forKey: profileKey) else { return nil }
        return try? JSONDecoder().decode(UserProfile.self, from: data)
    }

    func saveRuns(_ runs: [Run]) {
        if let data = try? JSONEncoder().encode(runs) {
            UserDefaults.standard.set(data, forKey: runsKey)
        }
    }

    func loadRuns() -> [Run] {
        guard let data = UserDefaults.standard.data(forKey: runsKey) else { return [] }
        return (try? JSONDecoder().decode([Run].self, from: data)) ?? []
    }

    func saveLocalRuns(_ runs: [LocalRun]) {
        if let data = try? JSONEncoder().encode(runs) {
            UserDefaults.standard.set(data, forKey: localRunsKey)
        }
    }

    func loadLocalRuns() -> [LocalRun] {
        guard let data = UserDefaults.standard.data(forKey: localRunsKey) else { return [] }
        return (try? JSONDecoder().decode([LocalRun].self, from: data)) ?? []
    }

    func addLocalRun(_ run: LocalRun) {
        localRuns.insert(run, at: 0)
        saveLocalRuns(localRuns)
        // Sync to backend fire-and-forget, then stash the backend-assigned id locally.
        Task { @MainActor in
            if let backendRun = try? await APIService.shared.postRun(run.toBackendRun()) {
                if let idx = localRuns.firstIndex(where: { $0.date == run.date }) {
                    localRuns[idx].id = backendRun.id
                    saveLocalRuns(localRuns)
                }
            }
        }
    }

    // MARK: - Sign out (clears local data + signs out of Clerk)

    func signOut() async {
        do {
            try await Clerk.shared.auth.signOut()
        } catch {
            print("[AppState] signOut error: \(error.localizedDescription)")
        }
        // Clear local storage — same as AsyncStorage.clear() in the RN app
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: runsKey)
        UserDefaults.standard.removeObject(forKey: localRunsKey)
        userProfile = nil
        runs = []
        localRuns = []
        hasProfile = false
        bootDone = false
    }
}
