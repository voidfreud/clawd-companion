# CLAUDE.md

Guidance for Claude (and people) working in this repository.

## What this is

Desk Clawd: a pixel-art desktop pet for macOS. One HTML page holds all of Clawd (drawing, behaviour, speech). A small Swift app hosts that page in a transparent, click-through overlay and feeds it facts about the desktop.

## Layout

| Path | Role |
|---|---|
| `desk-clawd.html` | All of Clawd: SVG body, state machine, physics, speech, menus, both host bridges. No build step. |
| `native/main.swift` | macOS host: overlay panel, WKWebView, menu bar item, cursor hit-testing, window edges, idle time, front app, Accessibility. |
| `native/build.sh` | Compiles `main.swift`, wraps the page in a document skeleton, strips web-font links, signs, optionally installs (`--install`). |
| `native/Info.plist` | Bundle id `local.deskclawd`, `LSUIElement` (no Dock icon), macOS 13+. |

## Build and run

```bash
./native/build.sh            # build into native/build/
./native/build.sh --install  # build, replace /Applications/Desk Clawd.app, relaunch
swiftc -typecheck native/main.swift   # quick Swift check
```

Syntax-check the page's script:

```bash
awk '/<script>/{f=1;next} /<\/script>/{f=0} f' desk-clawd.html > /tmp/clawd.js && node --check /tmp/clawd.js
```

## Two hosts, one page

The page detects its host at startup:

- **Native app:** `window.webkit.messageHandlers.clawd` exists → `startNative()`; mode `overlay`.
- **Claude artifact / desktop app:** `window.claude.use('desktop')` → overlay via the artifact desktop API (`setIgnore`, tray, permissions).
- **Plain browser:** mode `page`, Clawd walks inside the page.

Keep the page working in all three. Native-only features (window edges, idle, front app, interface) must degrade to "nothing happens" when their inputs never arrive.

## Bridge (native ↔ page)

Native → page, via `evaluateJavaScript("window.clawdNative.<fn>(…)")`:

| Call | When | Meaning |
|---|---|---|
| `pointer(x, y)` | ≤15 Hz while the mouse moves | Cursor in page coordinates (eye tracking) |
| `idle(sec, keySec)` | every 1 s | Seconds since any input / since last keypress |
| `windows([{id,x1,x2,y,wx}])` | 4 Hz, only on change | Visible top-edge segments of normal windows, front-most first |
| `app(bundleId, name)` | on app switch | Front app |
| `ui({type, …})` | Accessibility events | `status`, `granted`, `focus` (`kind`: text/search/password/other, `rect`), `dialog` (`title`, `text`, `buttons`, `rect`), `window` (`title`), `hover` (`role`, `label`) |
| `pet() snack() ball() nap() stay() size(k) color(k)` | menu bar | Actions |
| `visible(bool)` | hide/show | Hidden pauses the frame loop entirely |
| `save()` | before quit | Flush state to localStorage |

Page → native, via `postMessage`:

| `type` | Payload | Meaning |
|---|---|---|
| `hit` | `all`, `rects` | Where clicks should land; Swift hit-tests the cursor itself and flips `ignoresMouseEvents` |
| `state` | `size color stay sleeping food energy joy` | Mirrors into the menu bar menu |
| `hide` | | Hide the panel |

Coordinates: page origin is the top-left of the primary display's visible frame. Swift converts from global top-left (CoreGraphics / Accessibility) using `pageTop`.

## Behaviour model (desk-clawd.html)

- `S.state` drives everything: `idle walk seek eat chase sleep happy held fall crouch sit look stretch wave dance exit gone enter type alert cover`.
- `decide()` picks the next activity from weighted tables (floor vs. window top; `prefs.stay` removes all movement).
- `S.on` is the window edge Clawd stands on (`null` = floor). `groundY()`, `xMin()`, `xMax()` follow it. `fall` lands on edges it crosses while descending.
- Speech: `say(text, ms, icon)`. `fresh(list)` avoids recent repeats. `uiTalk()` rate-limits interface reactions, with separate quiet periods for window-title chatter (`win:`) and direct reactions.
- Needs drain per `RATE`; time passes while the app is closed (catch-up at load).

## Performance rules

- The frame loop has tiers (`tier()`): 60 fps only for physics (`held fall chase crouch`, ball, falling snacks), 30 fps for small motion, 12 fps idle, stopped when hidden. New states must be added to the right tier set.
- `setA`/`setR` skip unchanged SVG attributes; keep using them.
- Swift sends nothing while inputs are unchanged. Don't add per-frame `evaluateJavaScript` calls.

## Gotchas

- **Globals in `main.swift`:** top-level code runs in order and never gets past `app.run()`. A global constant declared below it is never initialised. C callbacks (e.g. `axCallback`) must be plain functions.
- **Chromium/Electron apps** expose no accessibility tree until asked: `watch()` sets `AXManualAccessibility` on the app element.
- **Standard search fields** focus an inner text editor; the search subrole is on its parent (`isInSearchField`).
- **AX calls can block:** messaging timeout is 0.25 s; only the front app is observed.
- **Window list** needs no Screen Recording permission as long as window names are never read.
- **Ad-hoc signing** changes per build, so macOS may drop the Accessibility grant after a rebuild. With an Apple Development identity in the keychain, `build.sh` uses it and the grant persists.
- **No network** in the native app: `build.sh` strips the Google Fonts links; the page falls back to system fonts. Don't add remote resources.

## Testing

- **Browser harness:** serve a copy of the built `clawd.html` with a mock `window.webkit.messageHandlers.clawd` injected into `<head>`, open it with `#debug` in the URL, then drive Clawd through `window.clawdNative.*` and inspect `window.clawdDebug` (`S`, `stats`, `prefs`, `go`, `decide`, `planClimb`, `planExit`, `hopDown`, `onIdle`, `onApp`, `onUi`, `think`, `platforms()`).
- **Real app:** use a throwaway test window (a tiny Swift script with `NSWindow`, text/secure/search fields and an `NSAlert` sheet) and screenshots. Clawd is random and may be off-screen; check the debug log (`defaults write local.deskclawd debugLog -bool true`, `~/Library/Logs/DeskClawd.log`) rather than relying on one screenshot.
- To test without touching your own Clawd's saved state, copy the built app, change its `CFBundleIdentifier`, and re-sign ad hoc. (It won't have the Accessibility grant.)

## Privacy rules

- Nothing about the user leaves the Mac or is stored. Interface data is used to pick a reaction and then dropped.
- Never read window contents, screen pixels, or text field values. Labels, titles, roles and dialog text only.
- Accessibility stays opt-in from the menu bar.
