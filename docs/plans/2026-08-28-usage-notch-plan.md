# Codenotch — Implementation Plan

Spec: `docs/specs/2026-08-28-usage-notch-design.md`
Started: 2026-08-28

Milestones are ordered so that something visible runs on screen by the end of M2, and
every later milestone can be cut without leaving the app broken.

---

## M0 — Project skeleton

- [ ] `project.yml` for XcodeGen: app target `Codenotch` + unit test target
- [ ] `Makefile` with `gen` / `build` / `test` / `run` / `clean`
- [ ] `Sources/Info.plist` with `LSUIElement: true`, min system 26.0
- [ ] `Sources/App/CodenotchMain.swift` + `AppDelegate` that launches with no window
- [ ] `make run` puts a running, invisible agent app in the process list

**Done when:** `make build` succeeds and `make run` starts a process with no Dock icon.

---

## M1 — The notch surface

- [ ] `NotchGeometry` — resolve the target screen, right-edge anchor rect, safe insets
- [ ] `SideNotchShape` — vertical pill with inverse rounded corners top and bottom
- [ ] `NotchPanel` — non-activating `NSPanel`, `.statusBar` level, joins all spaces,
      ignores mouse events outside the notch path
- [ ] `NotchWindowController` — owns the panel, re-anchors on screen-parameter changes
- [ ] Snapshot test / screenshot check of the shape against `docs/design/frame-124-*.png`

**Done when:** a black side notch sits on the right edge over every space and fullscreen
app, and clicks pass through everywhere except the notch itself.

---

## M2 — Provider cells (static data)

- [ ] `DesignSystem/Palette.swift` — black, `#2A2A2A`, `#3A3A3A`, green/yellow/orange
- [ ] `DesignSystem/Typography.swift` — percent label, tooltip label/value styles
- [ ] `UsageState` enum mapping `usedFraction` → colour band (0–49 / 50–79 / 80–99 / 100)
- [ ] `ProviderRing` — arc from 12 o'clock, clockwise, animatable `trim`
- [ ] `ProviderCell` — ring + glyph + percent label
- [ ] `NotchStackView` — data-driven vertical stack, 1–5 cells
- [ ] Provider glyphs as SF-Symbol-style template assets (Claude, OpenAI, slot 3)
- [ ] Hard-coded fixtures at 73% / 21% / 52% to match the mockup exactly

**Done when:** the running app is pixel-close to `frame-124-hover-tooltip.png` minus
the tooltip.

---

## M3 — Hover tooltip

- [ ] `NSTrackingArea` per cell, hover state published to SwiftUI
- [ ] `TooltipCard` — header, one `LimitWindowRow` per window, 4pt track bars
- [ ] `TooltipTail` — triangle aligned to the vertical centre of the hovered cell
- [ ] Positioning: left of the notch, clamped to stay on screen for the top/bottom cells
- [ ] 180ms spring in, 250ms grace before out, so the pointer can cross the gap
- [ ] Panel expands its hit region only while a tooltip is showing

**Done when:** hovering each cell reproduces `frame-125-detail.png`, and moving the
pointer from cell to card does not dismiss it.

---

## M4 — Data layer

- [ ] `UsageProvider` protocol + `Snapshot` / `LimitWindow` / `Fidelity` / `Status` models
- [ ] `UsageStore` — actor owning snapshots, refresh scheduling, staleness marking
- [ ] `ClaudeCodeLocalProvider` — parse `~/.claude/projects/**/*.jsonl`, sum tokens into
      the rolling 5-hour window, derive `usedFraction` against a configured plan ceiling
- [x] `ManualProvider` — user-declared limits, app-side counter, reset scheduling
- [ ] Refresh on a 60s timer, on wake, and on `Refresh now`
- [ ] Status rendering: `.stale` dims the ring, `.needsAuth` shows a lock glyph,
      `.derived` / `.manual` numbers get a "~" prefix in the tooltip
- [ ] Unit tests: window bucketing, reset-time maths, colour-band boundaries,
      relative-vs-absolute reset copy at the 60-minute edge

**Done when:** the Claude cell moves on its own as you use Claude Code.

---

## M5 — Settings + persistence

- [ ] `Preferences` (SwiftData or plist) — enabled providers, order, plan ceilings,
      auto-hide mode, launch at login
- [ ] Settings window: provider list with drag-to-reorder, per-provider config sheet
- [ ] Right-click menu: Settings…, Refresh now, Hide for 1 hour, Quit
- [ ] Launch at login via `SMAppService`

**Done when:** you can add, remove, reorder and configure providers without a rebuild.

---

## M6 — Polish

- [ ] Threshold notifications (80% / 100%) with per-provider mute
- [x] Auto-hide modes: never / on fullscreen / on any window overlapping the notch
- [ ] Multi-display: follow the active screen, handle unplug
- [ ] Reduced-motion and reduced-transparency support
- [ ] App icon, name decision, `README` screenshots

---

## Open questions

1. **Name.** `Codenotch` is a placeholder.
2. **Third provider.** The glyph in the mockup's third slot is not identified — which
   service is it? (Gemini, Cursor, Copilot, Perplexity…)
3. **Plan ceilings.** The local Claude Code adapter needs to know your plan's session
   ceiling to turn tokens into a percentage. Configured by hand, or inferred from the
   highest usage ever observed?
4. **Web-session adapters.** Out of v1 by default. If ChatGPT usage is a must-have for
   v1, that decision needs making explicitly, with the fragility accepted.

## Risks

- **Data fidelity is the whole product.** If the numbers are wrong, a beautiful notch is
  worse than nothing. M4 ships behind `.derived` labelling for exactly this reason.
- **Right-edge real estate** collides with scrollbars and some apps' inspectors. Auto-hide
  and a vertical offset setting are the mitigations.
- **Non-activating panels over fullscreen apps** are historically finicky; M1 is
  deliberately first so this is proven before any product code is written on top.
