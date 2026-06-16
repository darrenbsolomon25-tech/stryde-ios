# Stryde iOS — current state

Last updated: 2026-06-10 (Overpass 406 fixed + deployed; generateRoute timeout 20s→60s; route generation confirmed on a physical device; Item C "Back to Home" pop-to-root DONE — confirmed in the simulator)

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

### DEBUG-only Clerk sign-in bypass (Simulator testing)

Clerk sign-in fails intermittently in the Simulator (TLS / session errors),
which has repeatedly blocked testing the authenticated screens. There is now a
DEBUG-only bypass that skips Clerk entirely and boots straight into Home with a
seeded fake profile.

- **How to turn it on:** Xcode → Product → Scheme → Edit Scheme → Run →
  Arguments → "Arguments Passed On Launch" → add `-StrydeAuthBypass` (tick it).
  Untick to return to the real Clerk flow. (CLI equivalent:
  `xcrun simctl launch <udid> com.runstryde.Stryde-IOS -StrydeAuthBypass`.)
- **What it does:** `AppState.authBypassEnabled` (in `AppState.swift`) reads that
  launch arg; when set, `AppState.init` calls `enableDebugSession()` which seeds a
  complete `userProfile`, sets `hasProfile = true` and `bootDone = true`.
  `ContentView` has a `#if DEBUG` branch that, when the flag is on, renders the
  app shell directly — skipping the `Clerk.shared.user == nil` gate and `boot()`.
- **Can't ship:** `authBypassEnabled` is hard-wired to `false` in Release and the
  seed code is inside `#if DEBUG`, so none of it compiles into a Release build.
- **Reaching the run flow offline:** `boot()` is skipped so `APIService.tokenGetter`
  stays nil — the real `/generate-route` would 401. So in bypass mode
  `APIService.generateRoute` returns a **canned loop** (`APIService.cannedRoute`,
  `#if DEBUG`) built as a circle around the current GPS, with waypoints[0] pinned to
  the start so HomeView's snap check passes. This makes Quick Run / Build My Run →
  RoutePreview → RunView → Summary → History fully testable with no backend.
- **Still 401s in bypass:** profile/run *sync* (touch, getProfile, getRuns, postRun).
  Those are fire-and-forget or fall back to UserDefaults, so the UI still works; the
  run-save path keeps the run locally regardless of the failed POST.
- **Cosmetic:** greeting shows "Runner" and Settings/Drawer email are blank because
  `Clerk.shared.user` is nil. Harmless.
- **Testing the Waze marker:** to see the live marker glide along the route, set a
  *moving* simulated location (Xcode Debug bar → location → City Run, or load a GPX).
  A static location still lets you reach and eyeball RunView, just without movement.
- **Verified 2026-06-14:** with the arg → HomeView; without it → SignInView. Build
  (Debug, iPhone 17 Pro sim) + both launch paths confirmed. Canned route compiles;
  run-flow tap-through not yet manually walked.

---

## What's broken / half-wired

- **[RESOLVED 2026-06-10] Route generation was 502ing everywhere outside
  Manhattan.** Overpass started rejecting no-`User-Agent` requests (HTTP 406),
  killing every cold-tile graph fetch. Fixed in the backend (`overpass.js` now
  sends a User-Agent; deployed to Railway, commit `6247b9e`). Confirmed end-to-end:
  a real route generated on a physical iPhone in Englewood NJ. Paired iOS change:
  `generateRoute` timeout raised 20s→60s (`APIService.swift` `jsonFetch` gained a
  `timeout` param), since a cold Overpass fetch runs ~22–44s and the old 20s
  ceiling cut it off before the backend could answer.
- **[RESOLVED 2026-06-11] Background location now enabled for the run path.**
  Previously `project.pbxproj` declared only
  `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription`, so
  `CLLocationUpdate.liveUpdates(.fitness)` stopped the moment the screen locked or
  the app backgrounded, meaning a real run with the phone pocketed would record
  nothing. Two-part fix: (1) project now declares
  `INFOPLIST_KEY_UIBackgroundModes = location` plus
  `INFOPLIST_KEY_NSLocationAlwaysAndWhenInUseUsageDescription` in both Debug and
  Release configs; (2) `RunView` opens a `CLBackgroundActivitySession` in
  `startTracking()` and invalidates it in `stopTracking()`, which is what the
  streamlined `liveUpdates` API requires to keep delivering fixes while
  backgrounded. The session is held on `RunRef` so it lives for the whole run.
  Still needs the actual outdoor run to confirm the stream genuinely survives a
  screen lock on-device (part of the open Item B test below).
- **RunView GPS tracking still not confirmed on-device** — route generation →
  preview now works on a real device, but the live-run path (Start Run → GPS
  tracking → summary) has still never been validated on an actual outdoor run.
  This remains the open Item B test. Code is substantially
  improved (EMA smoothing, segment projection, fitness GPS mode, animated camera,
  exact polyline split) but a real outdoor run test is still needed to confirm
  step advancement, distance accumulation, and camera follow mode work correctly.
- **`postRouteFeedback` wiring confirmed** — fires on "Start Run" (accept) and
  "Regenerate" (reject). Backend logs to `routes.jsonl`. Training script joins
  feedback rows to request rows by `requestId`. Daily cron retrains weights.
  `outLengthM`/`returnLengthM` now logged in request rows so `symmetry` feature
  trains correctly.
- **Backend URL hardcoded** — `APIService.swift:91`. No dev/staging switch.
- **Turn-by-turn advance logic** — step advances at 30m proximity. Needs a real run
  to confirm the cadence feels right.

## RunView improvements (coded, not yet device-tested)

- GPS mode: `.automotiveNavigation` → `.fitness` (correct for running pace).
- EMA smoothing (alpha=0.3) on incoming GPS coordinates before display — reduces
  satellite-bounce jitter on the runner marker without adding lag.
- `nearestRoutePoint` replaces `updatePassedWaypoints` — orthogonal segment
  projection means the chevron slides continuously along the polyline instead of
  snapping to discrete waypoints. Lookahead window of 60 segments.
- `completedCoords` / `remainingCoords` extracted as computed properties — fixes
  `@MapContentBuilder` compilation restriction (let bindings not allowed inside).
- Completed segment: grey #666666, 4pt. Split is exact at projected runner position.
- Camera animated: `.linear(0.8s)` follow mode, `.linear(0.5s)` overhead.

## previousRequestId wiring (coded)

`APIService.generateRoute()` now accepts `previousRequestId`. `RoutePreviewView`
passes `route.requestId` on every Regenerate tap. Backend pops the next cached
survivor (~500ms) instead of running the full pipeline (~2-3s).
Verify the 2026-05-15 backend deploy is live on Railway before relying on this.

## "Back to Home" pop-to-root (Item C — DONE 2026-06-10)

The run-summary "Back to Home" button now collapses the whole NavigationStack to
HomeView in one tap, instead of `dismiss()` popping a single level back to RunView.

Mechanism (NOT a NavigationPath — the whole app is `isPresented`-bool navigation):
the two run-flow *entry* pushes were lifted into `AppState` as `showRoutePreview`
(Quick Run) and `showBuildRun` (Build My Run). Setting a root push flag back to
false removes that screen and every screen pushed above it, so the stack collapses
to root. `AppState.popToHome()` clears both; `RunSummaryView` calls it after a real
run (and still `dismiss()`es one level when opened read-only from Run History).

- `AppState.swift` — added `showRoutePreview`, `showBuildRun`, `popToHome()`.
- `HomeView.swift` — Quick Run push now binds `Bindable(appState).showRoutePreview`;
  "Build My Run" converted from a `NavigationLink` to a Button + a
  `navigationDestination(isPresented: Bindable(appState).showBuildRun)` (had to be
  flag-driven so popToHome can collapse it too).
- `RunSummaryView.swift` — button branches on `fromHistory`: post-run → popToHome,
  history → dismiss.

NOTE on why not a real NavigationPath: every push in the app is a separate
`isPresented` bool (+ NavigationLinks). A NavigationPath only controls screens
appended to it, and `CLLocationCoordinate2D` isn't Hashable, so the "proper" path
refactor would mean converting ~8 push sites across 6 files + adding Hashable
conformances. Deferred as out of scope for this UI fix.

**Confirmed in the simulator (2026-06-10):** Quick Run → Start Run → End Run →
summary → "Back to Home" lands directly on HomeView with no intermediate screens,
on both the Quick Run and Build My Run flows. Item C done.

## Not yet built (iOS-specific)

- TestFlight upload + first beta testers

## Backend state

Railway was offline 2026-05-24 – 2026-06-04 (trial expired). Restored 2026-06-04.
Backend confirmed live: `GET /health` → `{"status":"ok"}`.

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

**2026-05-15 — route quality improvements (not yet deployed):**

4. **Anchor jitter.** `sampling/sectors.js` now adds a random 0–45° offset to
   all 8 sector bearings per request. Same user, same location, same distance
   now produces a different loop every time.

5. **Survivor cache for Regenerate.** After ranking, `v2/index.js` stores
   runners-up (ranked[1..n]) in memory keyed by `requestId`, with nav steps
   pre-computed. When the app sends `previousRequestId` on Regenerate, the
   backend pops the next survivor and only runs a Claude naming call (~500ms)
   instead of the full pipeline (~2-3s). Falls back to full pipeline with fresh
   jitter when survivors are exhausted or cache expires (10 min TTL).

6. **`symmetry` training feature fixed.** `outLengthM` and `returnLengthM` are
   now logged in the `type:"request"` row so `train-reranker.js` can compute
   the `symmetry` feature correctly. Previously defaulted to 1.0 (symmetric)
   for all training examples.

See `stryde-route-service/STATE.md` for full backend state.

---

## Things that look like features but aren't

- Preference learning: zero implementation (routes use profile prefs, but no
  feedback loop to learn from run history yet)
- Street names in turn-by-turn: steps say "Turn left" with no street name
  (graph doesn't store OSM street names; a future build-graph rebuild adds them)
- `terrain.hilly` pref axis: parsed but unused (no elevation data in graph yet)
