# Stryde iOS — current state

Last updated: 2026-05-09 (loop fallback fix deployed; color scheme unified to #27272D)

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

7. **RunView** — live GPS tracking via `LocationManager`. Accumulates distance with
   `haversineDistanceMiles`. Camera modes: follow (behind-runner, pitch 65) and
   overhead (north-up). Step-by-step nav: advances `currentStep` when within 30m
   of the step's location. Timer counts up. "Finish Run" → `RunSummaryView`.
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

- App icon + splash (Assets.xcassets still has Xcode placeholders)
- "Back to Home" UX after a run (currently requires tapping back 2-3 times through
  the NavigationStack — need a dedicated "Done" button that pops to root)
- Error UX in BuildRunView
- TestFlight upload + first beta testers

## Backend state

The route dispatcher (`route/index.js`) now falls back from v2 (Overpass OSM graph)
to v1 (Mapbox loop pipeline) when the graph load fails with "Could not load graph".
Committed `bbbf003`, deployed to Railway 2026-05-09. Loop generation now works
globally even when Overpass is rate-limited or slow.

See `stryde-route-service/STATE.md` for full backend state.

---

## Things that look like features but aren't

- `customRequest` and `profile` reach the backend but routing ignores them (future)
- Personalization: profile is sent, but generation doesn't use it yet
- Preference learning: zero implementation
