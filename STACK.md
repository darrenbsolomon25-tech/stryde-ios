# Stryde iOS — stack & accounts

One-page map of every external service the project depends on. If something
breaks, start here. If a service is added or an account changes, update the
matching row **in the same sitting**.

Last updated: 2026-05-09

---

## GitHub — source code

| Repo | URL | Purpose |
|---|---|---|
| `Stryde IOS` | https://github.com/darrenbsolomon25-tech/stryde-ios | SwiftUI iOS app (this repo) |
| `stryde-route-service` | https://github.com/darrenbsolomon25-tech/stryde-route-service | Node/Express backend |

- Account: `darrenbsolomon25-tech`
- Auth: `gh auth login` (GitHub CLI, logged in via browser)
- Both repos are **private**.

## Railway — backend hosting + database

- Dashboard: https://railway.app
- Project: `stryde-route-service`
- Services:
  - **Node service** — auto-deploys from `stryde-route-service` GitHub repo, `main` branch.
    Public URL: `https://stryde-route-service-production.up.railway.app`
  - **Postgres 18** — managed addon. `DATABASE_URL` injected into Node service.
- Env vars on the Node service: `MAPBOX_ACCESS_TOKEN`, `ANTHROPIC_API_KEY`, `DATABASE_URL`,
  `CLERK_SECRET_KEY` (Railway-managed).

## Mapbox — directions, tilequery (backend only)

- Dashboard: https://account.mapbox.com
- Used by: **backend only** (Directions walking profile + Tilequery on `mapbox-streets-v8`
  for terrain classification). The iOS app uses **MapKit**, not the Mapbox SDK.
- Key: `MAPBOX_ACCESS_TOKEN` in Railway env only.

## Apple MapKit — map tiles + routing display (app only)

- Built into iOS — no account, no key, no SDK install required.
- Used by: iOS app only (`Map`, `MapPolyline`, `UserAnnotation`, `MapCameraPosition`).
- The old React Native app used `@rnmapbox/maps` with a Mapbox public token.
  The Swift rewrite dropped that entirely.

## Anthropic — Claude API (backend only)

- Dashboard: https://console.anthropic.com
- Used by: backend only (`validateAndNameRoute` with `claude-sonnet-4-5`).
- Key: `ANTHROPIC_API_KEY` in Railway env.

## Clerk — auth

- Dashboard: https://dashboard.clerk.com — project "Stryde"
- Handles: email + password sign-in/sign-up with email OTP verification.
- iOS SDK: `ClerkKit` (Swift Package Manager). Configured in `Stryde_IOSApp.swift`
  via `Clerk.configure(publishableKey:)`.
- Publishable key: `pk_test_cmFyZS1sYW1wcmV5LTM5LmNsZXJrLmFjY291bnRzLmRldiQ`
  (hardcoded in `Stryde_IOSApp.swift` — public key, safe to commit).
- Backend secret key: `CLERK_SECRET_KEY` in Railway env. `@clerk/backend` verifies
  JWTs and attaches `req.userId` on all protected endpoints.

## Xcode — build + simulator

- Xcode 16+ required (Swift 5.9+, `@Observable` macro).
- Run on device: plug in iPhone, select device in Xcode toolbar, Cmd+R.
- Simulator: works for UI testing, but GPS/location features need a real device.
- Bundle ID: `com.runstryde.app`
- Team: Darren Solomon (Apple Developer account)

## Apple Developer — TestFlight + App Store

- Dashboard: https://developer.apple.com
- App Store Connect: https://appstoreconnect.apple.com
- App record: "Stryde Running" (App ID: 6766527466)
- Bundle ID: `com.runstryde.app` registered
- TestFlight upload: Product → Archive in Xcode → Distribute App → App Store Connect
  (no EAS Build needed for the native Swift app — Xcode handles it directly)

## OSM / Geofabrik + Overpass — walkable graph (backend only)

- Source: https://download.geofabrik.de/ (free daily regional PBF extracts)
- `osmium-tool` installed locally via Homebrew for graph building
- Prebuilt graph: `stryde-route-service/graphs/manhattan.json` (96,747 nodes)
- On-demand (Tier 2): `route/v2/graph/overpass.js` hits `https://overpass-api.de/api/interpreter`
  (rate-limited, 60s timeout). If this fails, the dispatcher falls back to v1 (Mapbox).

---

## Secrets — where keys actually live

Never commit real secret keys. The Clerk publishable key is a public key and is
intentionally committed in source.

| Key | Lives in | Notes |
|---|---|---|
| `MAPBOX_ACCESS_TOKEN` | Railway env (backend) | Backend only — not in the iOS app |
| `ANTHROPIC_API_KEY` | Railway env (backend) | Backend only |
| `DATABASE_URL` | Railway env (Postgres addon → Node service) | Backend only |
| `CLERK_SECRET_KEY` | Railway env (backend) | JWT verification |
| Clerk publishable key | `Stryde_IOSApp.swift` (committed) | Public key — safe to commit |

---

## When something breaks — where to look first

| Symptom | Check |
|---|---|
| App can't reach the backend | Railway dashboard → is Node service healthy? `GET /db-health` should return `{ ok: true }` |
| Loop generation fails (502) | Railway logs — look for "Could not load graph". If Overpass is down, the dispatcher should auto-fallback to v1. Check `route/index.js`. |
| One-way routes fail | Railway logs — Mapbox 401 (key expired/quota) or Anthropic 401 |
| Auth errors / can't sign in | Clerk dashboard → project "Stryde" → check user records |
| DB queries fail | Railway → Postgres addon → running? `GET /db-tables` should list `users`, `profiles`, `runs`, `_migrations` |
| Map doesn't render | Check iOS location permissions + `LocationManager.authorizationStatus`. MapKit requires no key but does require location permission for `UserAnnotation`. |
| Xcode can't find ClerkKit | File → Packages → Resolve Package Versions in Xcode |
