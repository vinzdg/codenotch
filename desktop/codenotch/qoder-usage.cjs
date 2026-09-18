// qoder-usage.cjs — Sidecar that queries Qoder account usage via the official SDK.
// Spawned by qoder.rs; prints a single JSON object on stdout, exits 0 on success or 1 on any error.
// Auth: reuses the local signed-in qodercli session via qodercliAuth(), read-only.

(async () => {
  let sdk;
  try {
    sdk = require('@qoder-ai/qoder-agent-sdk');
  } catch (e) {
    process.stdout.write(JSON.stringify({ error: 'sdk_missing', message: e.message }));
    process.exit(1);
  }

  const { startDaemon, qodercliAuth } = sdk;
  let daemon = null;
  let out;
  let code = 0;

  try {
    // The handshake starts the runtime and landed at ~18s cold on the machine this was built
    // against; the 15s default failed it and looked like an auth problem.
    try {
      daemon = await startDaemon({ auth: qodercliAuth(), initializeTimeoutMs: 60_000 });
    } catch (e) {
      const msg = e?.message || String(e);
      out = { error: /auth|login|credential|sign.?in|token/i.test(msg) ? 'needsAuth' : 'daemon_failed', message: msg };
      code = 1;
      return;
    }

    // The documented signal for "no local login": the daemon borrows the qodercli session
    // read-only and answers false when it finds none. Guessing this from an error message
    // made a signed-out machine look like a broken one.
    if (typeof daemon.auth === 'function') {
      let landed = false;
      try {
        landed = await daemon.auth();
      } catch (e) {
        out = { error: 'needsAuth', message: e?.message || String(e) };
        code = 1;
        return;
      }
      if (!landed) {
        out = { error: 'needsAuth', message: 'qodercli has no stored sign-in to borrow' };
        code = 1;
        return;
      }
    }

    try {
      const usage = await daemon.getUsageInfo();
      out = { usage: usage ?? null };
    } catch (e) {
      const msg = e?.message || String(e);
      out = { error: /auth|login|unauthorized|forbidden|credential/i.test(msg) ? 'needsAuth' : 'query_failed', message: msg };
      code = 1;
    }
  } finally {
    if (daemon) {
      try {
        await daemon.stop();
      } catch (_) {}
    }
    process.stdout.write(JSON.stringify(out ?? { error: 'query_failed', message: 'the sidecar produced no result' }));
    process.exit(code);
  }
})();
