# Stryde iOS roadmap

Last updated: 2026-05-24

---

## What we're building

Stryde is a loop route generator. The bet: open the app, say what you want (or just pick a distance), and get a genuinely good loop from wherever you are — the right terrain, the right difficulty, real turn-by-turn navigation home. 30 seconds from open to running.

The differentiator is not social features, a community marketplace, or weather widgets. It's that the generator is actually good. Routes that match your preferences for real. Natural language requests that change the actual route, not just the name it gets called. A system that learns from your runs over time.

Everything on this roadmap is in service of that. If an idea doesn't make the route better or the running experience better, it's not on this list.

---

## How to use this file

- Work items are in priority order.
- **Each item = one fresh chat.** Start a new conversation, paste the heading into your first message, say "let's do this one."
- Check items off (`[x]`) when done. Update `STATE.md` before closing the chat.
- Don't jump ahead. Blocked-by notes are real — skipping creates more work.
- Completed items move to `ROADMAP_COMPLETED.md`.

Legend: 🔒 = security / correctness, 🔧 = wiring, 🎨 = UI, 📦 = release, 🏛 = architecture.

---

## A. ✅ Error UX in BuildRunView — DONE 2026-05-24

`errorMessage` state + `Route Error` alert added. Both catch blocks in
`generateRoute()` and `retryWithSuggestedStart()` now surface errors instead
of swallowing them silently. Matches the HomeView pattern exactly.

---

## B. 🏛 RunView GPS validation on device [START A NEW CHAT]

**Goal:** RunView code is written but has never been confirmed working on a real device
with real GPS movement. Needs an actual outdoor run test.

**What to verify:**
- Distance accumulates correctly via `haversineDistanceMiles` as the runner moves
- Step advancement fires at the right 30m threshold
- Camera follow mode (pitch 65, behind-runner) stays locked on the runner
- "Finish Run" → RunSummaryView with correct distance/duration/pace
- Run saves to `AppState.localRuns` and appears in RunHistoryView after

**Touches:** `Stryde IOS/RunView.swift` (likely fixes needed after real-device test)

**Done when:** you can run an actual loop and end up with a correct history entry.

---

## C. 🎨 "Back to Home" UX after a run [START A NEW CHAT]

**Blocked by:** B.

**Goal:** after finishing a run and viewing the summary, the user currently has to
tap "back" 2-3 times through the NavigationStack to get home. One "Done" button
should pop the entire stack to root.

**Touches:** `Stryde IOS/RunSummaryView.swift`, possibly `HomeView.swift`

**Done when:** tapping "Done" on RunSummaryView lands you directly on HomeView
with no intermediate screens.

---

## D. ✅ PostRouteFeedback wiring — DONE 2026-05-15

Confirmed wired. iOS fires `postRouteFeedback("accept")` on "Start Run" and
`postRouteFeedback("reject")` on "Regenerate". Backend logs to `routes.jsonl`.
Training script joins by `requestId`. Daily cron retrains weights.

---

## E. 📦 TestFlight beta [START A NEW CHAT]

**Blocked by:** B, C.

**Goal:** get the app in front of real testers. Nothing else matters until this is done.
Real people running real routes will tell you what to fix in the generator. You cannot
know that from the simulator.

**What to do:**
1. Product → Archive in Xcode
2. Distribute App → App Store Connect → TestFlight
3. Add external testers in App Store Connect

**Apple Developer account:** enrolled ✅
**Bundle ID:** `com.runstryde.app` ✅
**App Store Connect:** "Stryde Running" (App ID: 6766527466) ✅

**Done when:** you and at least one other person can install the app via TestFlight
and run a real loop.

---

## E.5. 📦 Business infrastructure [DO IT YOURSELF — any time]

**Blocked by:** nothing.

1. Register a domain (`stryde.run` or `stryde.app`) via Namecheap or Cloudflare Registrar.
2. Google Workspace Starter (~$6/mo). Point MX records at Google.
3. `hello@stryde.run` + `noreply@stryde.run`. Set noreply as sender in Clerk email templates.
4. Optional: one-page landing site at the domain via Cloudflare Pages or Vercel.

**Done when:** Clerk OTPs arrive from `noreply@stryde.run`.

---

## F. 🏛 Graph rebuild — elevation + street names [START A NEW CHAT]

**Blocked by:** E (get TestFlight feedback first; this is a multi-day infrastructure change).

**Why this item exists:** two preferences currently do nothing.

- `terrain.hilly` is parsed, weighted, and scored — but the graph has no elevation data,
  so every route scores as if all terrain is flat. Asking for "something hilly" silently
  produces the same route as "something flat."
- Turn-by-turn says "Turn left" with no street name. The graph doesn't store OSM `name`
  tags. Navigation feels broken even when the directions are correct.

Both problems require rebuilding the edge graph. Do them together — same Geofabrik data
pull, same build-graph.js pass, one deploy.

**What to do:**
- Pull elevation from SRTM (30m resolution, free, global) or OSM `ele` tags during
  graph build. Store `elevationGainM` on each directed edge.
- Pull `name=*` from OSM way tags during graph build. Store on each edge.
- Update `steps.js` to include street name in turn instructions.
- Update `weights.js` to use `elevationGainM` for the `terrain.hilly` axis.
- Rebuild `graphs/manhattan.json` and deploy. Overpass-built graphs rebuild automatically
  on next request since `overpass.js` calls `buildGraph` fresh.

**Done when:** "Turn left onto Broadway" appears in turn steps, and requesting a hilly
5km loop in Manhattan produces a meaningfully different route than requesting a flat one.

---

## G. 🏛 Natural language route requests that actually work [START A NEW CHAT]

**Blocked by:** F (needs elevation in the graph for hilly/flat intent to do anything).

**Why this matters:** this is the actual AI differentiator. Right now the `customRequest`
field sends free text to the backend, Claude wraps it into the route name, and the route
itself is unchanged. Nobody else is doing real intent-to-graph-weight mapping for running.

"Something hilly in the first half, flat finish so I can sprint home" should produce a
meaningfully different route than "something flat the whole way." Right now it doesn't.

**What to do:**
- `parse.js` already extracts a prefs vector from `customRequest` via Claude — this part
  is built. Verify the extracted prefs are actually being forwarded into `edgePenalty`.
- Confirm `edgePenalty` in `weights.js` is reading the elevation data added in item F.
- Add a small set of end-to-end test cases: hilly request vs. flat request at the same
  start/distance — verify the scored routes are actually different, not just named differently.
- If extraction is working but routes don't diverge, the gap is in `edgePenalty` knobs —
  tune alpha/beta until there's a visible difference.

**Done when:** same start point, same distance, "hilly" vs. "flat" request produces
routes with measurably different elevation profiles.

---

## H. 🔧 Live navigation — turn card + audio cues [START A NEW CHAT]

**Blocked by:** B (confirmed GPS), F (street names in graph).

**Goal:** during a run, a persistent turn card shows the next maneuver with distance
("In 80m, turn left onto Oak St"). Optional audio cue at approach.

Right now RunView shows steps but there's no persistent HUD and no audio. Navigation
feels passive. This makes it active.

**What to do:**
- Add a persistent turn card overlay in RunView (distance to next step + instruction).
- `AVSpeechSynthesizer` for audio: speak the step when 100m out, once.
- Steps already advance at 30m proximity — the trigger exists, just needs the HUD wired to it.

**Done when:** running a loop, you hear "In 80 meters, turn left onto Main Street" and
the card updates as you move through steps.

---

## I. 🏛 Post-run feedback + preference learning [START A NEW CHAT]

**Blocked by:** E (need real users generating data first). Don't build this until
you have at least 20 runs logged by real testers — the reranker needs signal to train on.

**Goal:** Stryde gets better the more you use it. Right now accept/reject from
RoutePreviewView is the only signal. That's a weak proxy — the user may accept a route
they end up hating halfway through.

**What to do:**
- Add a simple prompt to RunSummaryView after a real run: "How was this route?" with
  three options (Loved it / Fine / Didn't love it) + optional free text. Fire this to
  a new `POST /run-feedback` endpoint. Log to `routes.jsonl` as `type:"run-feedback"`.
- Update `train-reranker.js` to weight run-feedback rows more heavily than preview
  accept/reject rows (run feedback is ground truth; preview feedback is intent).
- After 10+ labeled runs per user, the reranker weights should reflect what that user
  actually enjoys running.

**Done when:** after 10 runs with ratings, the routes Stryde suggests measurably differ
from what a fresh user gets — reflecting the user's actual run history.

---

## J. 📦 App Store submission [START A NEW CHAT]

**Blocked by:** B, C, E, F, G (the generator should actually be good before the
App Store — TestFlight is for finding out if it is).

**Done when:** Stryde is live in the App Store.

---

## Parking lot

These are not on the roadmap. They may happen after J if the core generator is proven.

- **Custom start location** — pick a start somewhere other than your GPS. Valid, not urgent.
- **Landmarks mode** — run past famous places. Good idea, needs the graph + NL foundation from F and G first.
- **Trip mode** — routes for upcoming travel. Blocked on landmarks being solid.
- **Manual route editor** — drag waypoints. Power user feature, not the core use case.
- **Weather / AQI widget** — doesn't make the route better.
- **Route sharing / community browse** — needs density that doesn't exist yet. Revisit after App Store.
- **Android** — after iOS is stable.
- **Web version** — not planned.
