# Stryde iOS — current state

Last updated: 2026-06-29 (Run + Walk mode, branch `walk-mode` off `wip-migration`; backend off `main`. Compiles by inspection only — NOT yet Xcode-built or device-tested, backend NOT yet deployed to Railway. Stryde now generates walks as well as runs. (1) Onboarding asks run / walk / both on the fitness step; editable in Settings. Stored local-only in UserDefaults via `AppState.activityMode` + sticky `selectedActivity`; `effectiveActivity` is what's sent. (2) A Run/Walk toggle shows on Quick Run + Build for "both" users only (single-mode users are fixed by their mode). Walks are entered in MINUTES (converted at ~3 mph by `milesFromDisplay`); runs in miles. (3) `activity` is threaded the whole flow — HomeView/BuildRun → `/generate-route` → `GeneratedRoute` → RunView → RunSummary → stamped on the saved `LocalRun` (optional field, legacy rows read as `.run`). Regenerate preserves it. History shows a per-row run/walk badge; on-screen wording follows the activity. (4) Backend: walks get a "good walk" prefs overlay (floor quiet + avoid-arterials, NOT forced-scenic), start at the door (no `suggestedStart` relocation; v1 door-loop fallback), and bypass the run-trained reranker. (5) First real outdoor run (item B) passed 2026-06-29 — core GPS confirmed; that run was pre-`wip-migration` so Waze-motion + save-on-stop still want one confirming run. NOT verified: iOS Xcode build, on-device run/walk eyeball, Railway deploy.)

Last updated: 2026-06-26 (First-run fixes, post first on-device run. Builds clean (simulator), not yet device-tested; backend changes not yet deployed to Railway. (1) Start gate widened from 10 ft → 50 ft, and now widens further to the live GPS horizontal accuracy when that's looser — 10 ft never tripped on real hardware. (2) Auto-finish: once the runner loops back within 25 ft of the final waypoint (after covering ≥85% of the loop), a full-screen prompt auto-appears — "End Run" (default) or "Keep running". (3) BuildRunView: tapping Generate with no distance now shows a red banner instead of a silently-dimmed button; distance is the ONLY required field (terrain/elevation stay optional). (4) Terrain display is now REAL: backend returns `terrainDescription` + `terrainTags` computed from the chosen route's surface/park/water tags; app shows them in the preview subtitle, the "Terrain" stat (primary surface, not a chip count), and the summary. (5) Route naming no longer hallucinates: backend reverse-geocodes the start (Mapbox) and builds the name from the real street/neighborhood + actual terrain — no more "Harlem" for a NJ run. NOT done this pass: terrain *influence* on routing and the "Hills" axis (still no elevation data) — separate engine-quality work.)

Last updated: 2026-06-23 (RunView now opens in a walk-to-start phase: the timer/distance stay frozen while the runner walks to the route's first waypoint; the Start button stays locked until within 10 ft of it, then a 5→1 countdown flips to live tracking — so a run no longer starts counting while the runner is still walking to the line. Built as a phase inside RunView, not a separate screen. Coded + builds clean, not yet device-tested. Earlier same day: RunView heading now route-derived via look-ahead bearing instead of GPS `loc.course`)

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
   **Validation (2026-06-26):** distance is the only required field; tapping Generate
   without it shows a red `distanceErrorBanner` (the button stays tappable-but-dimmed so
   the tap can fire it), cleared the moment a distance chip/custom value is set. Terrain,
   elevation and special requests remain optional.

6. **RoutePreviewView** — shows the generated route as a MapKit `MapPolyline` on a
   bounds-fit map. Route name, terrain description, distance, estimated time.
   **Terrain (2026-06-26):** `terrainDescription` and the "Terrain" stat now reflect the
   route's REAL terrain from the backend (`terrainTags`), not a hardcoded string and a
   chip count. The stat shows the primary surface (`route.terrain.first`).
   "Start Run" → `RunView` (which opens in its walk-to-start phase, below).
   "Regenerate" → re-calls `generateRoute` and replaces the route in place. Fires
   `postRouteFeedback("accept")` / `("reject")` on those taps.
   Note: `postRouteFeedback` is defined in `APIService` but the call in `RoutePreviewView`
   may not be wired yet — verify before marking done.

7. **RunView** — live GPS tracking via `CLLocationUpdate.liveUpdates(.fitness)`.
   **Walk-to-start phase:** the route's first waypoint is usually 20-30 ft away (the
   loop snaps to the nearest path), so RunView opens in `phase == .approachingStart`
   with the timer and distance frozen at zero. A blue "Walk to your start point" card
   shows the live feet-to-start, the chevron + follow-camera point at the start, and
   the whole loop is drawn. The bottom button stays **locked until the runner is within
   `unlockRadiusFeet` (10 ft) of `route.waypoints.first`** (`isAtStart`); a muted "GPS
   off? Start anyway" link is the escape hatch so a bad fix can't trap them. Tapping
   Start (or the bypass) runs a 5→1 countdown overlay, then `startRunningPhase()` flips
   to `.running`, anchors `lastCoord` so the walk leg isn't counted, zeroes the
   clock/odometer, and starts the timer. **Start gate (2026-06-26):** `unlockRadiusFeet`
   is now **50 ft**, and `isAtStart` opens at `max(50 ft, live GPS accuracy)` — 10 ft was
   too tight to ever trip outdoors. **Auto-finish (2026-06-26):** `checkFinish` arms once
   `passedWaypointIndex ≥ 85%` of the loop; within `finishRadiusFeet` (25 ft) of the last
   waypoint it sets `showFinishPrompt`, a full-screen overlay with **End Run** (default →
   `handleStop`) and **Keep running** (latches `finishPromptDismissed` so it won't nag on
   later laps). Approach detection + freezing live in
   `processLocation`; the EMA smoothing and marker tween are factored into
   `updateSmoothed` / `retargetMarker`, shared by both phases.
   Accumulates distance with `haversineDistanceMiles` (raw GPS). Camera modes:
   follow (behind-runner, pitch 65, animated) and overhead (north-up, animated).
   Step-by-step nav: advances `currentStep` when within 25m of the step's location.
   Timer counts up. "End Run" → `RunSummaryView`.
   GPS is smoothed via exponential moving average (alpha=0.3) before display.
   Runner chevron projects onto nearest route segment (`projectOnSegment`) so it
   stays on the polyline. Completed segment renders grey (#666666, 4pt); remaining
   orange (#FF6B35, 6pt); split is exact at the projected runner position.
   Camera animates between fixes (.linear 0.8s follow / 0.5s overhead).
   Heading (chevron rotation + follow-camera bearing) is derived from the **route
   geometry** at the snapped position, not from GPS `loc.course` — see the
   "route-locked heading" note below.
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

## Route-locked heading (coded 2026-06-23, not yet device-tested)

The runner arrow and the follow-camera used to take their heading from
`loc.course` — the GPS course-over-ground. That value is jittery at running pace
and meaningless when slow/stationary, so the arrow spun around independently of
the route (it read as "the pointer reacts to which way the phone faces").

Heading is now derived purely from the **route polyline**:

- New `RunView.routeHeading(fromIndex:at:)` — from the runner's snapped position it
  walks ~20 m forward along the route waypoints and returns the bearing to that
  look-ahead point. Look-ahead (vs. the immediate segment) is deliberate: waypoints
  are dense and per-segment bearings are noisy, so aiming a short distance ahead
  gives a stable "where the path goes next" direction. Near the finish it aims at
  the final waypoint; returns `nil` only with no path left (caller keeps last heading).
- `processLocation` no longer reads `loc.course`; after snapping it computes
  `routeHdg` and feeds it into the existing heading tween, so turns still sweep
  smoothly — just toward the route's direction, not the GPS course.
- `RunView.init` seeds the initial heading + camera from the route's opening bearing
  (waypoints[0]→[1]) so it starts facing down the path instead of north-then-swinging
  on the first fix. `RunRef.init` gained a `startHeading` param.
- `LocalRun.swift` — extracted a numeric `bearingDegrees(...)` (0–360°) helper;
  `bearingCardinal` refactored to call it. Shared by `RunView`.

Net effect: follow mode rotates the camera so the route ahead fills the screen
(arrow points up); overhead mode keeps the map north-up and rotates the arrow along
the route. Either way the pointer is fixed to the route, not the phone. Needs the
same outdoor run test as Item B to confirm it tracks correctly through turns.

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
