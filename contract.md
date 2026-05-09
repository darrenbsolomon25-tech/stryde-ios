# App ↔ route service contract

Last updated: 2026-05-09 (iOS rewrite; contract unchanged from RN version)

If this doc drifts from `Stryde IOS/APIService.swift` or
`stryde-route-service/index.js`, fix one of them in the same sitting.

**Base URL:** `https://stryde-route-service-production.up.railway.app`

---

## Identity

Every request to a protected endpoint carries an `Authorization: Bearer <token>`
header. The token is a Clerk session JWT obtained from `Clerk.shared.auth.getToken()`
in the app. The backend verifies it with `@clerk/backend`'s `verifyToken` and
extracts `payload.sub` (the Clerk user ID, e.g. `user_2abc123...`) as `req.userId`.

Ops endpoints (`/health`, `/db-health`, `/db-tables`) require no auth.

---

## `POST /generate-route`

Requires `Authorization: Bearer <token>`.

### Request body

| Field           | Type              | Required | Notes |
|-----------------|-------------------|----------|-------|
| `lat`           | number            | yes      | -90 to 90 |
| `lng`           | number            | yes      | -180 to 180 |
| `distanceKm`    | number            | yes      | 1-42 |
| `routeType`     | `"loop"` / `"one-way"` | no | defaults to `"loop"` |
| `customRequest` | string / null     | no       | up to 500 chars; consumed by v2 preference parser |
| `profile`       | object / null     | no       | shape below; used by v2 scoring |
| `engine`        | `"v1"` / `"v2"` / null | no | explicit engine override for debugging |

#### `profile` shape

| Field               | Type       | Notes |
|---------------------|------------|-------|
| `fitnessLevel`      | string / null | `"Beginner"`, `"Intermediate"`, or `"Advanced"` |
| `terrain`           | string[]   | e.g. `["Parks", "Waterfront"]` |
| `preferredDistance` | string / null | e.g. `"3 mi"` |
| `goals`             | string[] / null | |

### Response body (200) — route generated

| Field          | Type     | Notes |
|----------------|----------|-------|
| `waypoints`    | `{ lat, lng }[]` | full polyline |
| `steps`        | `Step[]` | turn-by-turn maneuvers (shape below). May be empty. |
| `name`         | string   | Claude-generated route name |
| `distanceKm`   | number   | actual routed distance, 2 dp |
| `score`        | number   | internal; not for display |
| `valid`        | boolean  | Claude yes/no on geometry |
| `reason`       | string   | Claude's reason when `valid=false` |
| `routeType`    | string   | echo of request |
| `requestId`    | string / null | UUID for this v2 request; send back in `POST /route-feedback`. null for v1 routes. |
| `engine`       | `"v1"` / `"v2"` / `"v1-fallback"` | which engine produced the route |

### Response body (200) — suggested start

When the start location is too sparse to form a valid loop, the backend returns
a `suggestedStart` instead of a route. The app shows "Walk Xm direction" and
can retry `POST /generate-route` with the suggested coordinates.

| Field              | Type   | Notes |
|--------------------|--------|-------|
| `suggestedStart`   | object | present only when no route was generated |
| `.lat`             | number | suggested start latitude |
| `.lng`             | number | suggested start longitude |
| `.walkMeters`      | number | approximate walking distance from original start |
| `.direction`       | string | compass direction: `"north"`, `"northeast"`, ... |

#### `Step` shape

| Field             | Type   | Notes |
|-------------------|--------|-------|
| `instruction`     | string | e.g. "Turn left onto Oak St" |
| `type`            | string | Mapbox maneuver type (`turn`, `depart`, `arrive`, ...) |
| `modifier`        | string | e.g. `left`, `right`, `slight right` |
| `distanceMeters`  | number | length of this step's segment |
| `location`        | `{ lat, lng }` | maneuver point |
| `name`            | string | street/way name |

---

## `POST /route-feedback`

Requires `Authorization: Bearer <token>`.

Records a user accept/reject signal for the ML reranker.

### Request body

| Field       | Type              | Notes |
|-------------|-------------------|-------|
| `requestId` | string            | UUID from the `requestId` field in `POST /generate-route` response |
| `event`     | `"accept"` / `"reject"` | "accept" = user tapped "Start Run"; "reject" = tapped "Regenerate" |

Response: `{ "ok": true }`

---

## Persistence endpoints (all auth-gated)

All require `Authorization: Bearer <token>`. Identity comes from the token.

### `POST /users/touch`
Upserts the user row and bumps `last_seen_at`. Called on every app launch.
Request: `{}` (empty body). Response: `{ "ok": true }`

### `DELETE /users/me`
Permanently deletes the user's runs, profile, and user row (inside a transaction).
Call this before `Clerk.shared.auth.signOut()` so the JWT is still valid at request time.
Response: `{ "ok": true }`

### `GET /profile/me`
Returns the user's preferences, or `{ profile: null }` if none.
```json
{
  "profile": {
    "user_id": "user_2abc...",
    "fitness_level": "Intermediate",
    "terrain": ["Parks", "Waterfront"],
    "preferred_distance": "3 mi",
    "goals": ["Get fit"],
    "updated_at": "..."
  }
}
```

### `PUT /profile/me`
Replaces the user's preferences (upsert). PII (phone, age, gender) is intentionally
not synced — it stays in `UserDefaults` only.
```json
{
  "fitnessLevel": "Intermediate",
  "terrain": ["Parks"],
  "preferredDistance": "3 mi",
  "goals": ["Get fit"]
}
```
Response: `{ profile: <same shape as GET> }`

### `POST /runs`
Inserts a completed run. Server generates `id` (UUID) and `created_at`.
```json
{
  "startedAt": "2026-05-09T10:00:00Z",
  "endedAt": "2026-05-09T10:30:00Z",
  "durationS": 1800,
  "distanceKm": 5.2,
  "routeType": "loop",
  "routeName": "Morning Park Loop",
  "waypoints": [{ "lat": 40.7, "lng": -74.0 }],
  "steps": []
}
```
Response: `{ "run": { ...inserted row... } }`

Note: `distance_km` comes back as a **string** in the response (Postgres `NUMERIC`
serializes as a string via the `pg` driver). Parse with `Double(_)` on the Swift side.

### `GET /runs/me`
Returns up to 200 runs for the signed-in user, newest first by `started_at`.
Response: `{ "runs": [ ...run rows... ] }`

### `DELETE /runs/:id`
Deletes one run. `:id` is the server UUID from `POST /runs`.
Response: `{ "ok": true }` or 404 `{ "error": "not found" }`

---

## Operational endpoints (for debugging)

- `GET /db-health` → `{ ok, version, now }`
- `GET /db-tables` → `{ ok, tables: [{table_name, column_count}] }`

---

## Error responses

| Status | Body                              | When |
|--------|-----------------------------------|------|
| 400    | `{ error: "..." }`                | input validation failure |
| 401    | `{ error: "unauthorized" }`       | missing / invalid / expired JWT |
| 404    | `{ error: "not found" }`          | DELETE /runs/:id matched nothing |
| 500    | `{ error: "..." }`                | unhandled backend crash |
| 502    | `{ error, attempts, rejections }` | all route attempts failed |
