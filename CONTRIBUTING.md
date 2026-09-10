# Contributing

## Building

```sh
brew install xcodegen   # once — project.yml generates the .xcodeproj
make build               # Debug build, ad-hoc signed
make test                # unit tests
make run                 # build and launch
```

None of these need an Apple Developer account. `xcodebuild` ad-hoc signs a
Debug build automatically, which is enough to run and debug locally. An ad-hoc
identity changes every build, so a keychain "Always Allow" grant does not
survive a rebuild and the prompt reappears during development.

That prompt is no longer shown, in Debug or in a release build. It was never
only a development annoyance: a keychain item has an access list, which is what
"Always Allow" writes to, and a *partition list*, which nothing in the GUI ever
writes to. An app outside the partition list is refused before the access list
is consulted, so approving the dialogue is good for exactly one read. Claude
Code recreates its keychain items on every token rotation rather than updating
them, and a freshly created item's partition list holds only `apple-tool:` —
which evicts a properly signed release build just as surely as an ad-hoc one.
Shipped users got the dialogue on a timer.

`ClaudeCredentials.read` therefore disables keychain interaction for the length
of the read and falls back to `/usr/bin/security`, which is Apple-signed and so
is never the client that gets refused. A refusal it cannot recover from becomes
`.accessDenied`, and `Scripts/fix-keychain-partitions.sh` is the one thing that
actually restores direct access.

`make release` is different: it archives, signs with a Developer ID
certificate, notarizes with Apple, and regenerates the Sparkle auto-update
feed. That's the maintainer's job for cutting an official build, and it needs
credentials only the maintainer has. You won't need it to contribute.

## Before opening a PR

- `make test` passes.
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
