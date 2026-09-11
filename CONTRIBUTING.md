# Contributing

## Building

```sh
brew install xcodegen   # once — project.yml generates the .xcodeproj
make build               # Debug build, ad-hoc signed
make test                # unit tests
make run                 # build and launch
```

None of these need an Apple Developer account. `xcodebuild` ad-hoc signs a
Debug build automatically, which is enough to run and debug locally. The one
thing an unsigned build can't do is keep a keychain "Always Allow" grant across
rebuilds — Claude Code's and Antigravity's credentials are guarded by an ACL
keyed on the signing identity, and an ad-hoc identity changes every build. In
practice this means the keychain prompt reappears each time you rebuild during
development; that's expected and doesn't affect anything else.

`make release` is different: it archives, signs with a Developer ID
certificate, notarizes with Apple, and regenerates the Sparkle auto-update
feed. That's the maintainer's job for cutting an official build, and it needs
credentials only the maintainer has. You won't need it to contribute.

### Rust/Tauri port (Windows and Linux)

On Arch Linux, install or audit prerequisites with the repository's Justfile,
then build either profile:

```sh
just setup
just health            # use just cure-plan / just cure if required
just arch build
just arch release
just tests all
```

The Rust workspace lives under `windows/` for historical reasons and is shared
by Windows and Linux. Linux runtime behavior is currently verified on KDE
Plasma through XWayland. See the root README's
[Linux section](README.md#linux-arch-experimental) for installation and runtime
diagnostics.

## Before opening a PR

- `make test` passes.
- Rust/Tauri changes pass `just tests all`; Arch-specific changes also pass
  `just arch release`.
- New behavior has a test. `Tests/` mirrors `Sources/` by concern, not by
  file — look for the existing test class closest to what you're changing
  before adding a new one.
- If you're changing layout math in `Sources/Notch/NotchLayout.swift`, check it
  against `docs/design/frame-124-hover-tooltip.png` — every constant there is
  quoted from that frame in design-frame pixels via `Design.px(_:)`.

## Code style

- Comments explain **why**, not what — a hidden constraint, a bug a piece of
  code works around, a design decision that would otherwise look arbitrary.
  If removing a comment wouldn't confuse the next reader, it shouldn't be
  there.
- No premature abstraction. Three similar lines beat an early helper.
- A provider adapter (`Sources/Providers/`) should degrade every failure to a
  visible, honest status — `stale`, `needsAuth`, `accessDenied`, `error` — and
  never invent a number. See `UsageProviderError` and `ProviderStatus`.

## Visible copy

- User-visible strings (settings, menus, tooltips, notifications, What's New,
  provider labels and status) go through `L10n.t("English source")`. The
  English source **is** the key.
- English is the source language. Put optional translations in
  `Sources/Localizable.xcstrings`. A missing translation falls back to
  English and must not fail tests — do not gate CI on any locale being
  complete.
- Don't freeze `L10n.t` in a `static let` — lookup has to see the current
  language.
- Follow System plus the in-app Language setting; don't set `AppleLanguages`.
- Windows `windows/codenotch/src/i18n.rs` is a separate system — don't merge
  the two.

## Adding a provider

Implement `UsageProvider` (`Sources/Providers/UsageProvider.swift`). At
minimum:

- Declare a `Fidelity` — `.official` if the number comes from the vendor's own
  endpoint or local state, `.derived` if you computed it yourself (the
  tooltip prefixes a `~`), `.manual` if it's a placeholder.
- Every failure path should map to a `ProviderStatus`, not throw something the
  UI can't render — see how `ClaudeOAuthProvider` and `CodexLocalProvider`
  handle theirs.
- If the credential lives in the keychain, hold it with `CredentialCache`
  rather than reading on every poll — see its doc comment for why.

## Reporting a bug

Include the unified log around the time it happened:

```sh
/usr/bin/log show --last 10m --predicate 'subsystem == "com.vinz.codenotch"' --info --debug
```
