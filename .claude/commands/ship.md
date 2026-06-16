Close out the current roadmap item and commit the work. Follow these steps in order:

1. Read STATE.md and ROADMAP.md to confirm what item just finished and what the current status is.
2. Update STATE.md — mark the completed item as DONE, update the "Next up" line to the next item.
3. Update ROADMAP.md — check off the completed item.
4. Check if STACK.md needs updating (new dependencies, frameworks, or API changes introduced this session).
5. Check contract.md if any API endpoints changed.
6. Do a quick sanity check: scan any SwiftUI view changes for MapContent conformance issues or @Observable misuse, and confirm existing navigation flows (ContentView routing logic) still work.
7. Stage all changed files explicitly (not `git add .`) — list what you're staging.
8. Commit with a clear message following the existing commit style (check `git log --oneline -5` first).
9. Push to main.
10. Report back: what was closed, what files changed, what's next on the roadmap.
