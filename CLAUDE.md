# Stryde iOS — project map for Claude

## What it is
Stryde is a native iOS running app (SwiftUI) that generates personalized loop routes
and tracks runs with live GPS navigation. This repo is the iOS rewrite of the original
React Native app — same backend, same product, native Swift.

## Two repos

| Repo | Local path | What it does |
|---|---|---|
| `Stryde IOS` | `/Users/darrensolomon/Stryde IOS/` | SwiftUI iOS app (this repo) |
| `stryde-route-service` | `/Users/darrensolomon/stryde-route-service/` | Node/Express backend on Railway |

The old React Native app lives at `/Users/darrensolomon/stryde/` — it is retired.
Do not touch it or reference it for new work.

## Key entry files

**App:**
- `Stryde IOS/Stryde_IOSApp.swift` — app entry point; `Clerk.configure()` + `ClerkProvider`
- `Stryde IOS/ContentView.swift` — root view; routes between `SignInView`, `OnboardingView`,
  and `HomeView` based on `AppState.bootDone` + `AppState.hasProfile`
- `Stryde IOS/AppState.swift` — `@Observable` singleton; holds `userProfile`, `runs`,
  `localRuns`; owns the boot sequence (touchUser → syncProfile → syncRuns → loadLocalRuns →
  bootDone = true); `ContentView` reacts: no profile → `OnboardingView`, has profile → `HomeView`
- `Stryde IOS/APIService.swift` — all backend calls; shared `jsonRequest` helper with JWT
  via `tokenGetter`; 401 → `onAuthError` callback → sign out
- `Stryde IOS/LocalRun.swift` — `LocalRun` struct + `haversineDistanceMiles` + `parseMiles`
  + `bearingCardinal` helpers
- `Stryde IOS/LocationManager.swift` — `CLLocationManagerDelegate` wrapper for `@Observable`;
  feeds live GPS coordinates into `RunView` during active runs

**Screens (all in `Stryde IOS/`):**
- `SignInView.swift` — email + password sign-in/sign-up with Clerk
- `OnboardingView.swift` — 6-step form; collects fitness level, terrain, distance, goals
- `HomeView.swift` — map + Quick Run / Build My Run; route generation entry point
- `DrawerView.swift` — slide-in hamburger menu; Run History, Settings, Sign out
- `BuildRunView.swift` — distance / terrain / elevation / custom request form
- `RoutePreviewView.swift` — route on MapKit bounds-fit map before committing
- `RunView.swift` — live GPS tracking; follow/overhead camera modes; step-by-step nav
- `RunSummaryView.swift` — post-run stats; saves to `AppState.localRuns` + backend
- `RunHistoryView.swift` — list of past runs; long-press to delete
- `SettingsView.swift` — edit profile; collapsible sections; auto-saves

**Backend:**
- `route/index.js` — dispatcher: `pickEngine` → v2 for loops (with v1 Mapbox fallback if
  Overpass fails), v1 for one-ways
- `route/v1/index.js` — Mapbox pipeline (serves one-ways + fallback loops)
- `route/v2/index.js` — OSM graph engine: snap → intent → anchor search → scoring → reranker

## Stack

**App:** SwiftUI + `@Observable`. No TypeScript, no React Native. Persistence via
`UserDefaults` (JSON-encoded structs). Auth via ClerkKit; JWT sent on every request.
Map rendering via MapKit (no Mapbox SDK on the app side).

**Backend:** Node.js + Express, Postgres 18 on Railway, Mapbox Directions + Tilequery,
Claude for route naming. OSM pedestrian graph via Geofabrik (prebuilt) + Overpass (live).

Full service/account/key map: `STACK.md`. API contract: `contract.md`.

## Current state

See `STATE.md` (this repo) and `stryde-route-service/STATE.md` (backend) for what is
actually built and what is broken. Don't trust memory — read the files.

## Route Generation

When touching route generation (`overpass.js` or the v2 engine in `stryde-route-service`), watch for these recurring failure modes:
- Overpass 406 errors — always send a `User-Agent` header
- Terrain/surface scoring bugs — verify the prefs vector is parsed and applied correctly
- Loop algorithm correctness — routes must close back to the start point
- Empty navigation steps — validate the response before returning

## Hard rules

1. **Explain every piece of code you share.** The user is learning Swift — don't just
   write it, teach it. Explain what each keyword and pattern does.
2. **Edit files directly.** Use Edit/Write tools. Paste snippets only when explicitly asked.
3. **One roadmap item = one fresh chat.** Don't start the next numbered item in the same
   conversation, even if asked.
4. **Read state files before starting.** Always read `STATE.md` and `ROADMAP.md` at the
   start of a session before touching any code.
5. **Documentation on close.** When a roadmap item is done, update `STATE.md`, `ROADMAP.md`,
   and `STACK.md` as needed, then commit in the same session.
6. **Build & verify.** After editing SwiftUI views or navigation logic, check for compile
   errors (e.g. `MapContent` conformance, `@Observable` misuse) and confirm existing
   navigation flows still work before declaring done.
