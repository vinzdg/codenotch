# Decision: Web-Session Adapters (ChatGPT / OpenAI) on Future Roadmap

**Date:** 2026-10-12  
**Status:** Decided — Out of Scope  
**References:** `TASKS.md` ("Decisions needed", line 1846); `docs/plans/2026-08-28-usage-notch-plan.md` ("Open questions", item 4); `docs/specs/2026-08-28-usage-notch-design.md` (item 4).

---

## 1. Context & Origin

In the initial design of Codenotch, an open question was logged:
> *"Are web-session adapters (ChatGPT et al.) in scope for v1, accepting the fragility? Claude now answers this for itself: the OAuth endpoint is in, so the same question is live for OpenAI and Perplexity."* (`TASKS.md`, line 1846)

This document formalizes the evaluation and final roadmap decision regarding whether web-session adapters (specifically for ChatGPT / OpenAI via `WebSessionProvider` or browser session extraction) should be incorporated into the future roadmap.

---

## 2. Technical & Architectural Evaluation

### A. Session Fragility and Anti-Bot Defenses
- `chatgpt.com` operates behind aggressive Cloudflare Bot Management, Turnstile verification, Proof-of-Work puzzles, and device attestation.
- Automated web requests from headless or background `WKWebView` sessions routinely encounter CAPTCHAs, `403 Forbidden`, or Cloudflare challenge pages.
- Session tokens (`__Secure-next-auth.session-token`, access tokens) rotate unpredictably, causing frequent silent auth drops and degraded `.needsAuth` states.

### B. Privacy, Security, and Sandboxing
- Attempting to inspect or extract session cookies directly from external browsers (Google Chrome, Safari, Firefox) violates sandboxing principles, risks triggering system security warnings, and creates an unacceptable security and privacy footprint for users.
- Codenotch's architectural invariant is that it never reads browser cookie stores or writes user credentials to disk.

### C. Terms of Service and Account Safety
- Reverse-engineering and polling undocumented web frontend endpoints (`/backend-api/`) violates OpenAI's Terms of Service regarding automated extraction and scraping.
- Using fragile web-session scraping creates risks of account flags, shadow-throttling, or bans for end-users.

### D. Redundancy with Existing Native Providers
OpenAI and ChatGPT usage are already cleanly and reliably supported in Codenotch:
1. **`CodexLocalProvider` (Official / Local Session)**:
   - Reads the local session managed and refreshed by OpenAI's official Codex macOS app and CLI (`~/.codex` or `com.openai.codex`).
   - Directly and legitimately queries `https://chatgpt.com/backend-api/wham/usage` using authorized Bearer tokens and account headers.
   - Provides live 5-hour rolling limits and weekly allowance windows with zero session scraping or bot challenges.
2. **`CustomEndpointProvider` (API Billing)**:
   - Supports standard OpenAI API endpoints, token counters, and usage tracking using official API keys.
3. **Claude Parity**:
   - Claude resolved this identically: `ClaudeOAuthProvider`, `ClaudeCLI`, and `ClaudeDesktopUsageCache` superseded any need for web-session scraping.

### E. The Scoped Role of `WebSessionProvider`
`WebSessionProvider` remains in Codenotch, but is deliberately restricted:
- **Where retained**: DeepSeek Platform, QianwenAI, MiniMax, and Qoder. These platforms lack local CLI sessions on macOS, but provide web consoles that permit explicit, opt-in in-app `WKWebView` sign-in without hostile anti-bot walls.
- **Where deferred/unregistered**: Perplexity (`PerplexityUsage`) was implemented experimentally against `/rest/rate-limit/all`, but remains unregistered due to ongoing endpoint volatility.

---

## 3. Decision

1. **ChatGPT Web-Session Adapters are Out of Scope**:
   We will **not** build or maintain a ChatGPT web-session scraping adapter or `WKWebView`-based ChatGPT session provider on the roadmap.
2. **OpenAI / ChatGPT Coverage Anchors**:
   - Coding assistant usage limits continue to be provided exclusively by **`CodexLocalProvider`**, relying on the local Codex CLI / macOS application session.
   - Direct API usage continues to be supported through **`CustomEndpointProvider`**.
3. **`WebSessionProvider` Criteria**:
   `WebSessionProvider` will not be expanded to services protected by aggressive anti-bot defenses or services that already provide official local sessions.
