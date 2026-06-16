import Foundation
import ClerkKit

// @Observable replaces ObservableObject — any view that reads a property here
// will automatically re-render when that property changes. No @Published needed.
@Observable
@MainActor
class AppState {
    static let shared = AppState()
    private init() {
        #if DEBUG
        // When the "-StrydeAuthBypass" launch arg is set on the scheme, seed a
        // fake signed-in session before the first frame renders. See the
        // "Debug auth bypass" section below. This block is compiled out entirely
        // in Release, so the bypass can never reach a shipped build.
        if Self.authBypassEnabled { enableDebugSession() }
        #endif
    }

    // These three drive what ContentView renders, same as the flags in AppNavigator.js
    var bootDone = false
    var hasProfile = false

    // Controls the slide-in drawer (hamburger menu)
    var drawerOpen = false

    // Programmatic navigation flags set by DrawerView.
    // HomeView watches these to push screens onto the NavigationStack.
    var showRunHistory = false
    var showSettings = false

    // Run-flow entry flags. These live here — not as HomeView @State — so that
    // RunSummaryView, three or four screens deep, can flip them back to false and
    // collapse the whole stack to Home in one tap. HomeView drives its two forward
    // pushes off these: Quick Run (→ RoutePreview) and Build My Run (→ BuildRun).
    var showRoutePreview = false
    var showBuildRun = false

    // Local copies of the user's data — populated during boot
    var userProfile: UserProfile? = nil
    var runs: [Run] = []

    // Local run history (miles + pace shape, not the backend km shape)
    var localRuns: [LocalRun] = []

    // MARK: - Navigation

    /// Pops the entire run flow back to Home in one tap.
    ///
    /// Both entry paths hang off one of the two flags below at the *root* of the
    /// stack:
    ///   Quick Run:    Home → RoutePreview → Run → Summary   (root flag: showRoutePreview)
    ///   Build My Run: Home → BuildRun → RoutePreview → Run → Summary (root flag: showBuildRun)
    ///
    /// Setting a root flag back to false removes that screen *and every screen
    /// pushed above it*, so the stack collapses straight to HomeView. Only one
    /// flag is ever true at a time, so clearing both is always safe.
    func popToHome() {
        showRoutePreview = false
        showBuildRun = false
    }

    // MARK: - Debug auth bypass (DEBUG builds only)
    //
    // Why this exists: Clerk sign-in fails intermittently in the Simulator with
    // TLS / session errors, which blocks testing every authenticated screen. This
    // lets a DEBUG build skip Clerk completely and boot straight into Home with a
    // seeded profile, so the run flow / RunView / history / settings can be tested
    // in the sim without touching Clerk's network path.
    //
    // It is OFF by default even in DEBUG. It only activates when the
    // "-StrydeAuthBypass" launch argument is present on the scheme
    // (Product → Scheme → Edit Scheme → Run → Arguments → "Arguments Passed On
    // Launch"). Untick that argument and you're back to the real Clerk flow.
    //
    // `#if DEBUG` ... `#else return false` means: in a Release build this property
    // is hard-wired to false and the seed code below is stripped out, so the
    // bypass physically cannot ship.
    // `nonisolated` lets non-main-actor code (e.g. APIService) read this without an
    // actor hop. It's safe: it only reads ProcessInfo and touches no mutable state.
    nonisolated static var authBypassEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-StrydeAuthBypass")
        #else
        return false
        #endif
    }

    #if DEBUG
    /// Seeds a fake signed-in session so ContentView can render the app shell
    /// without Clerk and without running boot()'s network calls.
    ///
    /// - A *complete* `userProfile` (so `hasProfile` is true → we land on Home,
    ///   not Onboarding). Values mirror the option strings OnboardingView uses.
    /// - `bootDone = true` so ContentView skips the loading spinner.
    ///
    /// Note: because boot() never runs, `APIService.tokenGetter` stays nil, so any
    /// live backend call (route generation, profile/run sync) will 401. That's
    /// expected — this is for testing the local authenticated UI, not the backend.
    func enableDebugSession() {
        userProfile = UserProfile(
            fitnessLevel: "Intermediate",
            terrain: ["Parks", "Waterfront"],
            preferredDistance: "2 - 4 miles",
            goals: ["Get fit", "Explore new areas"],
            phone: nil,
            age: "28",
            gender: "Prefer not to say"
        )
        hasProfile = true
        bootDone = true
        print("[AppState] DEBUG auth bypass active — seeded fake profile, skipped Clerk + boot().")
    }
    #endif

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
        guard let data = UserDefaults.standard.data(forKey: localRunsKey) else {
            print("[AppState] loadLocalRuns: no data at key '\(localRunsKey)' — 0 runs.")
            return []
        }
        let decoded = (try? JSONDecoder().decode([LocalRun].self, from: data)) ?? []
        print("[AppState] loadLocalRuns: \(data.count) bytes → \(decoded.count) runs decoded.")
        return decoded
    }

    func addLocalRun(_ run: LocalRun) {
        localRuns.insert(run, at: 0)
        saveLocalRuns(localRuns)
        let persistedBytes = UserDefaults.standard.data(forKey: localRunsKey)?.count ?? 0
        print("[AppState] addLocalRun: saved '\(run.routeName)' "
            + "(\(String(format: "%.2f", run.distance)) mi, \(run.duration)s). "
            + "localRuns now \(localRuns.count); UserDefaults holds \(persistedBytes) bytes for key '\(localRunsKey)'.")
        // Sync to backend, then stash the backend-assigned id locally. The result is
        // logged rather than silently swallowed (was `try?`), so a failing /runs POST
        // is visible while testing. The run is always kept locally regardless.
        Task { @MainActor in
            do {
                let backendRun = try await APIService.shared.postRun(run.toBackendRun())
                if let idx = localRuns.firstIndex(where: { $0.date == run.date }) {
                    localRuns[idx].id = backendRun.id
                    saveLocalRuns(localRuns)
                }
                print("[AppState] postRun OK: backend id \(backendRun.id ?? "nil")")
            } catch {
                print("[AppState] postRun FAILED (run kept locally): \(error.localizedDescription)")
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
