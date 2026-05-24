# Stryde iOS roadmap

Last updated: 2026-05-24

How to use this file:

- Work items are numbered in priority order.
- **Each numbered item = one fresh chat.** When you log on, start a new conversation,
  paste the item's heading into your first message, and say "let's do this one."
- Check items off (`[x]`) as you finish them. Update `STATE.md` before closing the chat.
- Don't jump ahead. Items later in the list are blocked on earlier ones for real reasons
  (noted as "Blocked by:"). Skipping creates more work, not less.
- Completed items live in `ROADMAP_COMPLETED.md`.

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

**Blocked by:** item B (confirm the run flow works first).

**Goal:** after finishing a run and viewing the summary, the user currently has to
tap "back" 2-3 times through the NavigationStack to get home. One "Done" button
should pop the entire stack to root.

**Touches:** `Stryde IOS/RunSummaryView.swift`, possibly `HomeView.swift`

**Done when:** tapping "Done" on RunSummaryView lands you directly on HomeView
with no intermediate screens.

---

## D. ✅ PostRouteFeedback wiring verification — DONE 2026-05-15

Confirmed wired. iOS fires `postRouteFeedback("accept")` on "Start Run" and
`postRouteFeedback("reject")` on "Regenerate". Backend logs to `routes.jsonl`.
Training script joins by `requestId`. Daily cron retrains weights.
Also fixed: `outLengthM`/`returnLengthM` now logged in request rows so the
`symmetry` training feature works correctly (was always 1.0 before).

---

## 14. 📦 TestFlight beta [START A NEW CHAT]

**Blocked by:** items A, B, C, D, and 9.

**Goal:** get the app in front of beta testers via TestFlight.

**What you do:**
1. Product → Archive in Xcode (builds a release `.xcarchive`)
2. Distribute App → App Store Connect (uploads to TestFlight)
3. Add external testers in App Store Connect → TestFlight

No EAS Build needed — Xcode's native archive workflow handles this for a native Swift app.

**Apple Developer account:** enrolled ✅
**Bundle ID:** `com.runstryde.app` registered ✅
**App Store Connect record:** "Stryde Running" (App ID: 6766527466) ✅

**Done when:** you and at least one other person can install the app via TestFlight.

---

## 14.5. 📦 Business infrastructure — domain, email, Google Workspace [DO IT YOURSELF]

**Blocked by:** nothing. Can be done any time.

**Goal:** Stryde has a real home on the internet and a professional identity before
it hits the App Store.

**What to do:**
1. **Domain** — register `stryde.run` (or `getstryde.com`, `stryde.app`) via Namecheap
   or Cloudflare Registrar. Lock down WHOIS privacy.
2. **Google Workspace** — Starter plan (~$6/user/mo). Point MX records at Google.
3. **Stryde email** — at minimum `hello@stryde.run` and `noreply@stryde.run`.
   Set `noreply` as the sender in Clerk → Email Templates → From address.
4. **Landing page (optional)** — even a one-pager at `stryde.run`. Cloudflare Pages
   or Vercel, free tier.

**Done when:** you can send/receive email at `hello@stryde.run` and Clerk OTPs arrive
from `noreply@stryde.run`.

---

## 13. 🎨 Manual route editor [START A NEW CHAT]

**Blocked by:** item 14.

**Goal:** drag waypoints on the map; route recomputes on the walkable graph.

**Done when:** drag a waypoint 200m off the line, route snaps to real streets,
distance updates.

---

## 15. 🏛 Landmarks mode [START A NEW CHAT]

**Goal:** the differentiator. Run past real stuff — Colosseum, Forum, Trevi.

**Done when:** a 5km loop in Rome actually hits 3+ famous landmarks.

---

## 16. 🎨 Custom start location picker [START A NEW CHAT]

**Goal:** build a route starting somewhere other than current GPS location.

**Done when:** sitting at home, pick a spot in Central Park, get a route starting there.

---

## 17. 🎨 Weather / AQI / pollen widget on Home [START A NEW CHAT]

**Goal:** ambient data before the run decision.

**Done when:** Home shows current conditions for the user's location.

---

## 18. 🔧 Live navigation / turn-by-turn [START A NEW CHAT]

**Blocked by:** item B (needs confirmed RunView GPS first).

**Goal:** real navigation during the run — turn card, distance to next maneuver,
optional audio + haptic cues.

**Done when:** app says "in 100m, turn left onto Oak St" at the right moment.

---

## 19. 🏛 Preference learning [START A NEW CHAT]

**Goal:** the moat. Stryde gets sharper the more you use it.

**Done when:** after 10 runs, default route type reflects what you've actually been running.

---

## 20. 🏛 Trip mode [START A NEW CHAT]

**Blocked by:** items 15, 19.

**Goal:** "You're in Seoul next week — here's where to run."

**Done when:** enter a trip, app proactively suggests routes there without you asking.

---

## 21. 🏛 Optimal route mode [START A NEW CHAT — LAST]

**Goal:** AI finds the best run factoring in crowd density, time of day, skill level.

---

## 22. 📦 App Store submission [START A NEW CHAT]

**Blocked by:** items 9, 14.

**Done when:** Stryde is live in the App Store.

---

## Parking lot

- Android release — after iOS is stable
- Web version — not on the roadmap
- Preference learning / Redux — only if state management becomes painful
