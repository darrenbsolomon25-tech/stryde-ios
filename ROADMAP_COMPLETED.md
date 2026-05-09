# Stryde iOS roadmap — completed items

Items moved here once done. Full detail preserved for reference.

---

## Swift rewrite — all screens [DONE 2026-05-07 to 2026-05-09]

The original Stryde app was built in React Native (Expo SDK 55). After all the major
features were built and confirmed working in RN, the app was rewritten from scratch
in SwiftUI. The RN app is now retired.

**What shipped in the rewrite:**

- `SignInView` — email + password sign-in/sign-up via ClerkKit (Swift package)
- `OnboardingView` — 6-step form matching the RN onboarding shape
- `HomeView` — MapKit map + Quick Run / Build My Run; snap-distance alert;
  no-route suggestion alert; Route Error alert (added after loop bug debugging)
- `DrawerView` — slide-in hamburger; Run History, Settings, Sign out
- `BuildRunView` — full form matching `BuildRunScreen.js` shape
- `RoutePreviewView` — MapKit `MapPolyline` + bounds-fit camera
- `RunView` — live GPS tracking via `CLLocationManager`; follow/overhead camera;
  step-by-step nav; haversine distance accumulation
- `RunSummaryView` — post-run stats + `AppState.addLocalRun` + `postRun`
- `RunHistoryView` — `AppState.localRuns` list; long-press delete
- `SettingsView` — collapsible sections; auto-save to `UserDefaults` + `putProfile`
- `AppState` — `@Observable` singleton; boot sequence; `UserDefaults` persistence
- `APIService` — all backend calls; JWT via `tokenGetter`; 401 → sign-out callback
- `LocalRun` — `Codable` struct + `haversineDistanceMiles` + `parseMiles` + `bearingCardinal`
- `LocationManager` — `CLLocationManagerDelegate` wrapper for `@Observable`
- Color scheme unified: `#27272D` dark grey background (was `#0A0A0A` in earlier builds)

---

## Loop bug fix — v1 fallback in dispatcher [DONE 2026-05-09]

**Problem:** the v2 route engine (Overpass OSM graph) was always chosen for loop requests
because `hasGraphFor()` always returns truthy after Tier 2 was added. When Overpass was
rate-limited or slow, `fetchOverpassGraph()` threw `RouteError(502, "Could not load graph...")`.
There was no fallback — users got a 502 with no route.

**Fix:** `route/index.js` now wraps the v2 call in try/catch. If the error is a `RouteError`
with reason starting with "Could not load graph" and no explicit `engine` override was
requested, the dispatcher logs a message and falls back to `v1.generate(params)`, returning
`{ ...result, engine: 'v1-fallback' }`. Explicit `engine=v2` in the request body bypasses
the fallback (for engineering probes). Committed `bbbf003`, deployed 2026-05-09.

---

## 10.5. 🔒 Real auth via Clerk [DONE — 5 chats]

Full Clerk auth end-to-end. Email + password sign-in/sign-up with email OTP.
JWT on every request. User data follows users across devices. Sign-out. Delete account.
Token-expiry auto sign-out via 401 callback.

---

## 12. 🏛 Smart start suggestions [DONE 2026-04-24]

Two complementary behaviors: snap-distance alert (when `waypoints[0]` is >150m from GPS)
and no-route suggestion alert (when no loop is possible, backend returns `suggestedStart`
instead of 502). Both wired in `HomeView` and `BuildRunView`.

---

## 11. 🏛 OSM pedestrian-graph rewrite [DONE 2026-04-23]

v2 engine: bidirectional length-constrained A* over Geofabrik + Overpass OSM graph.
Intent parse, anchor sampling, deterministic hard gates, ML reranker, Claude naming.
Ships globally; any city on earth via Overpass Tier 2.

---

## 10. 🏛 Persistence layer [DONE 2026-04-21]

Postgres 18 on Railway. Users, profiles, runs. Keyed by Clerk `user_id` (post-auth).
Migration runner. All endpoints auth-gated.

---

## 8. 🎨 Route preview before starting [DONE]

`RoutePreviewView` — shows generated route on map before committing. "Regenerate" re-calls
the API. Confirmed working.

---

## Items 1–7 [DONE — see original RN ROADMAP_COMPLETED.md for detail]

These were completed during the React Native phase:
1. API key rotation
2. App ↔ backend contract wiring (customRequest, steps)
3. Backend hard gates (closure, distance ratio, backtrack)
4. Run History screen
5. Settings screen + drawer navigation
6. Real error UX
7. Camera mode toggle (follow / overhead)
