# Stryde iOS — current state

Last updated: 2026-05-10 (app icon added)

Source of truth for what the app **actually does right now**, not what it should do.
If you change something, update the relevant section in the same sitting.

For what to work on next, see `ROADMAP.md`.

---

## Stack

SwiftUI + `@Observable`. No TypeScript, no React Native. `UserDefaults` for local
persistence (JSON-encoded `Codable` structs). Auth via ClerkKit — JWT sent on every
API request via `APIService.tokenGetter`. Map rendering via MapKit (no Mapbox SDK
on the app side). Backend at `https://stryde-route-service-production.up.railway.app`.

## Screens

Navigation is a `NavigationStack` rooted in `ContentView`. `ContentView` shows
`SignInView` when not signed in, `OnboardingView` when signed in with no profile,
and `HomeView` when signed in with a profile. The drawer slides in as a `ZStack`
overlay on `HomeView`.

1. **SignInView** — email + password sign-in / sign-up. Uses Clerk's `SignIn` and
   `SignUp` flows. Email OTP verification. On success, `ContentView` re-evaluates
   `appState.bootDone` and routes appropriately.

2. **OnboardingView** — 6-step form. Collects fitness level, terrain preferences,
   preferred distance, and goals. Name and email come from Clerk and are never
   collected here. Fires `putProfile` to backend on submit (fire-and-forget).

3. **HomeView** — map (MapKit `UserAnnotation`) + Quick Run / Build My Run buttons.
   Greeting is "Good run, {firstName}" from `Clerk.shared.user?.firstName`.
   Quick Run shows a distance picker; tapping a distance calls `APIService.generateRoute`.
   Snap-distance alert if `waypoints[0]` is >150m from GPS fix.
   No-route suggestion alert if backend returns `suggestedStart`.
   Route Error alert if generation throws (shows `error.localizedDescription`).
   Custom distance text field (decimal pad).

4. **DrawerView** — slides in from left; ZStack overlay on HomeView. Shows "STRYDE"
   wordmark + signed-in email. Buttons: Run History, Settings, Sign out. Uses
   `DispatchQueue.main.asyncAfter` to let the close animation finish before pushing.

5. **BuildRunView** — distance / terrain / elevation / custom request text fields.
   Sends full `UserProfile` + `customRequest` to backend. Navigates to `RoutePreviewView`
   on success. Has silent `catch` blocks (error UX not yet added here — next item).

6. **RoutePreviewView** — shows the generated route as a MapKit `MapPolyline` on a
   bounds-fit map. Route name, terrain description, distance, estimated time.
   "Start Run" → `RunView`. "Regenerate" → re-calls `generateRoute` and replaces the
   route in place. Fires `postRouteFeedback("accept")` / `("reject")` on those taps.
   Note: `postRouteFeedback` is defined in `APIService` but the call in `RoutePreviewView`
   may not be wired yet — verify before marking done.

7. **RunView** — live GPS tracking via `CLLocationUpdate.liveUpdates(.fitness)`.
   Accumulates distance with `haversineDistanceMiles` (raw GPS). Camera modes:
   follow (behind-runner, pitch 65, animated) and overhead (north-up, animated).
   Step-by-step nav: advances `currentStep` when within 25m of the step's location.
   Timer counts up. "Finish Run" → `RunSummaryView`.
   GPS is smoothed via exponential moving average (alpha=0.3) before display.
   Runner chevron projects onto nearest route segment (`projectOnSegment`) so it
   stays on the polyline. Completed segment renders grey (#666666, 4pt); remaining
   orange (#FF6B35, 6pt); split is exact at the projected runner position.
   Camera animates between fixes (.linear 0.8s follow / 0.5s overhead).
   **Not yet confirmed working on device** — needs a real outdoor run test.

8. **RunSummaryView** — post-run stats (distance, duration, pace, route name).
   Appends a `LocalRun` to `AppState.localRuns` (via `addLocalRun`, which also
   fires `postRun` to backend fire-and-forget). Skips save when `fromHistory: true`.

9. **RunHistoryView** — list of `AppState.localRuns`. Tap → `RunSummaryView`
   (read-only). Long-press → Alert with Cancel / Delete. Delete removes from
   `localRuns` + fires `deleteRun` to backend if the run has a server id.

10. **SettingsView** — edit `UserProfile` after onboarding. Collapsible sections
    for Personal info (name read-only from Clerk, email read-only, phone/age/gender
    editable), Fitness level, Preferred terrain, Preferred distance, Goals.
    Auto-saves to `UserDefaults` on every change; preference fields also fire
    `putProfile` to backend (fire-and-forget).

## APIService calls

All requests go to `https://stryde-route-service-production.up.railway.app`.
Full request/response contract in `contract.md`.

`APIService.shared` exports:

- `touchUser()` — `POST /users/touch`, called on every launch from `AppState.boot()`
- `getProfile()` / `putProfile()` — preferences sync
- `generateRoute()` — returns `RouteResult` enum (`.route(GeneratedRoute)` or
  `.suggestedStart(SuggestedStart)`)
- `postRouteFeedback(requestId, event)` — `POST /route-feedback` with `"accept"|"reject"`
- `postRun()` / `getRuns()` / `deleteRun()` — run history sync

Shared `jsonRequest` helper: 20s timeout, surfaces backend `reason`/`error`.
401 responses fire `onAuthError` → `AppState` signs out via Clerk.

### Boot sequence (`AppState.boot()`)

1. Wire `tokenGetter` (Clerk JWT getter) and `onAuthError` (sign-out callback) into `APIService`.
2. `touchUser()` — upserts the user row.
3. `syncProfile()` — GET `/profile/me`; on failure, falls back to `UserDefaults`.
4. `syncRuns()` — GET `/runs/me`; on failure, falls back to `UserDefaults`.
5. `loadLocalRuns()` — reads `LocalRun` array from `UserDefaults`.
6. Set `hasProfile = userProfile != nil`, `bootDone = true`.
7. `ContentView` reacts: `hasProfile` false → `OnboardingView`; true → `HomeView`.

---

## What's broken / half-wired

- **RunView GPS tracking not confirmed on-device** — code is there, but a real
  outdoor run test is needed to confirm step advancement, distance accumulation, and
  camera follow mode all work correctly.
- **BuildRunView has silent catch blocks** — route generation errors aren't shown to
  the user (unlike HomeView, which has a `Route Error` alert). Needs the same fix.
- **`postRouteFeedback` wiring unverified** — check that `RoutePreviewView` actually
  calls it on "Start Run" and "Regenerate" before marking this done.
- **Backend URL hardcoded** — `APIService.swift:91`. No dev/staging switch.
- **Turn-by-turn advance logic** — step advances at 30m proximity. Needs a real run
  to confirm the cadence feels right.

## Not yet built (iOS-specific)

- "Back to Home" UX after a run (currently requires tapping back 2-3 times through
  the NavigationStack — need a dedicated "Done" button that pops to root)
- Error UX in BuildRunView
- TestFlight upload + first beta testers

## Backend state

Committed `d441884`, deployed to Railway 2026-05-12. Three root causes of bad
route quality fixed in a single deploy:

1. **Triangle loop generation (S→A→B→S).** The old S→A→S algorithm produced
   out-and-back parallel-street routes. The new approach samples two anchor
   nodes 60° apart and pathfinds three legs, each on different streets.
   Routes now go somewhere, cross over, and come back.

2. **Turn-by-turn steps populated.** `steps: []` was hardcoded since v2
   launched. `navigation/steps.js` now extracts real turn instructions from
   the winning route's node sequence. RunView navigation has actual steps.

3. **Profile preferences working for the first time.** iOS sends
   `terrain: ["Parks","Waterfront",...]` (array). Backend was reading
   `profile.preferredTerrain` (single string) — nothing ever matched, every
   request generated with all-zero prefs. Now fixed. Terrain selections from
   onboarding actually influence edge weights and route ranking.

See `stryde-route-service/STATE.md` for full backend state.

---

## Things that look like features but aren't

- Preference learning: zero implementation (routes use profile prefs, but no
  feedback loop to learn from run history yet)
- Street names in turn-by-turn: steps say "Turn left" with no street name
  (graph doesn't store OSM street names; a future build-graph rebuild adds them)
- `terrain.hilly` pref axis: parsed but unused (no elevation data in graph yet)
