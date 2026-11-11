# Claude unused resets

On September 23, 2026, Claude's web and Desktop Settings → Usage pages showed
one unused promotional reset expiring October 22. A read-only inspection of
their usage responses identified the optional `cedar_ember` block:

```json
{
  "cedar_ember": {
    "eligible": true,
    "ineligible_reason": null,
    "grants": [{
      "id": "example-grant",
      "resets_left": 1,
      "starts_at": "2026-09-22T16:00:00+00:00",
      "ends_at": "2026-10-22T16:00:00+00:00",
      "paused": false,
      "usable_now": true
    }]
  }
}
```

The web/Desktop request is
`GET /api/organizations/<organization>/usage?cedar_ember=1&skip_spend=1`.
Requests without `cedar_ember=1` return a null block. Desktop writes both
variants into its Chromium cache independently, so the newest usage entry
is not necessarily the one containing reset data. The reader retains the
newest windows and the newest reset response, each with its own age.
A spent or malformed block, or an explicit reset query returning no block,
supersedes older available grants. Organization
matching applies to reset data too. Desktop only refreshes reset grants while
Settings → Usage is open, so cached grants remain visible with their original
observation age until they expire or a newer response supersedes them. The
30-minute freshness limit still applies to usage windows.

Routine OAuth reads use plain `GET /api/oauth/usage`, without `cedar_ember`.
The earlier live reset-query check returned `eligible: false` and
`ineligible_reason: "surface"`, with no grants even though Desktop reported one.
Reset counts therefore come from the matching Desktop cache and can accompany
CLI or OAuth usage windows. Unavailable reset data is not zero remaining resets.
The decoder still tolerates an optional OAuth `cedar_ember` block if one appears;
there is no separate network request for grants.

The displayed count is the sum of positive `resets_left` values for eligible,
unpaused grants within their start/end dates. The expiry line uses the
soonest `ends_at`. `usable_now` is not the count: a grant requiring a usage
limit or cooldown can still be unused. The card does not redeem resets and
does not promise that redemption is possible immediately. No grant ID,
promotion deadline, or number of resets is hardcoded into the provider.

Malformed reset data must not prevent ordinary usage windows from displaying.
Expiry is also checked when rendering remembered snapshots. Existing Codex
copy, localization keys, and layout dimensions are reused; Windows remains
unchanged because it has no corresponding reset-credit card or Desktop cache
reader.

Regression coverage includes parsing, eligibility, grant timing, spent and
malformed responses, cache key alternation, account isolation, cache age,
provider fallbacks, and card rendering. Live checks only read availability;
they do not consume a reset.

To render a live card locally after opening Claude Desktop Settings → Usage:

```sh
TEST_RUNNER_CLAUDE_RESET_LIVE_RENDER_PATH=/tmp/claude-resets.png make test
```

This opt-in check reads the matching Desktop cache through the provider and
renders its actual snapshot. It never reads a credential or redeems a reset.
