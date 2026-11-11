// Run with node --test test-qoder-usage.cjs from windows/.
// The sidecar's contract with qoder.rs: exactly one JSON object on stdout, exit 0 with {usage} or
// exit 1 with {error, message}. Auth-shaped failures must arrive as needsAuth, never as a stack.
const { spawnSync } = require('node:child_process');
const { mkdtempSync, writeFileSync, cpSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const assert = require('node:assert/strict');
const { test } = require('node:test');

const SIDECAR = join(__dirname, 'codenotch', 'qoder-usage.cjs');

// A stand-in for @qoder-ai/qoder-agent-sdk: the real daemon needs a signed-in qodercli, and a
// usage test must not spawn inference or touch the network.
const MOCK = (scenario) => `
const s = ${JSON.stringify(scenario)};
exports.qodercliAuth = () => ({ kind: 'qodercli' });
exports.startDaemon = async (options) => {
  if (!options.auth || options.auth.kind !== 'qodercli') throw new Error('AUTH_PAYLOAD_REQUIRED');
  if (s === 'daemon_signin') throw new Error('no signed-in qodercli session — please sign in first');
  if (s === 'daemon_plain') throw new Error('daemon handshake failed');
  const daemon = {
    async getUsageInfo() {
      process.stderr.write('QUERIED');
      if (s === 'query_unauthorized') throw new Error('unauthorized (401)');
      if (s === 'query_null') return null;
      return { totalUsagePercentage: 40, expiresAt: 1760000000000,
               userQuota: { total: 100, used: 40, remaining: 60, unit: 'credits' }, userType: 'Pro' };
    },
    async stop() {},
  };
  // Some SDK builds carry no auth() at all; the sidecar must then read as before.
  if (s !== 'no_auth_method') {
    daemon.auth = async () => {
      if (s === 'auth_rejects') throw new Error('AUTH_PAYLOAD_REQUIRED');
      return s !== 'auth_no_login';
    };
  }
  return daemon;
};
`;

function run(scenario, { sdk = true } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'qoder-sidecar-'));
  try {
    if (sdk) {
      const pkg = join(dir, 'node_modules', '@qoder-ai', 'qoder-agent-sdk');
      require('node:fs').mkdirSync(pkg, { recursive: true });
      writeFileSync(join(pkg, 'index.js'), MOCK(scenario));
      writeFileSync(join(pkg, 'package.json'),
        JSON.stringify({ name: '@qoder-ai/qoder-agent-sdk', version: '0.0.0-test', main: 'index.js' }));
    }
    cpSync(SIDECAR, join(dir, 'qoder-usage.cjs'));
    const r = spawnSync(process.execPath, [join(dir, 'qoder-usage.cjs')], { encoding: 'utf8', timeout: 30_000 });
    return { code: r.status, out: r.stdout, err: r.stderr };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function envelope(scenario, opts) {
  const { code, out, err } = run(scenario, opts);
  assert.doesNotThrow(() => JSON.parse(out), `stdout must be one JSON object, got: ${JSON.stringify(out)}`);
  return { code, err, json: JSON.parse(out) };
}

test('signed-in path prints the raw getUsageInfo payload', () => {
  const { code, json } = envelope('ok');
  assert.equal(code, 0);
  assert.equal(json.usage.userQuota.remaining, 60);
  assert.equal(json.usage.totalUsagePercentage, 40);
  assert.ok(!('error' in json));
});

test('a daemon failure that names signing in is reported as needsAuth', () => {
  const { code, json } = envelope('daemon_signin');
  assert.equal(code, 1);
  assert.equal(json.error, 'needsAuth');
});

test('an unexplained daemon failure is daemon_failed, not a fake auth ask', () => {
  const { code, json } = envelope('daemon_plain');
  assert.equal(code, 1);
  assert.equal(json.error, 'daemon_failed');
});

test('a rejected usage query is needsAuth', () => {
  const { code, json } = envelope('query_unauthorized');
  assert.equal(code, 1);
  assert.equal(json.error, 'needsAuth');
});

test('a null getUsageInfo passes through as usage:null (qoder.rs decides)', () => {
  const { code, json } = envelope('query_null');
  assert.equal(code, 0);
  assert.equal(json.usage, null);
});

test('without the SDK next to it, the script says sdk_missing instead of throwing', () => {
  const { code, json } = envelope('ok', { sdk: false });
  assert.equal(code, 1);
  assert.equal(json.error, 'sdk_missing');
});

// The daemon borrows the local qodercli sign-in read-only and answers false when there is none.
// That is the documented "not signed in" answer, so the sidecar must not spend a usage query on it.
test('a daemon that lands no credential says needsAuth without asking for usage', () => {
  const { code, err, json } = envelope('auth_no_login');
  assert.equal(code, 1);
  assert.equal(json.error, 'needsAuth');
  assert.ok(!err.includes('QUERIED'), 'getUsageInfo must not run when no credential landed');
});

test('a rejected auth() is needsAuth, still without a usage query', () => {
  const { code, err, json } = envelope('auth_rejects');
  assert.equal(code, 1);
  assert.equal(json.error, 'needsAuth');
  assert.ok(!err.includes('QUERIED'));
});

// An SDK build whose daemon has no auth() must keep working rather than crash on the guard.
test('a daemon without auth() still reads usage', () => {
  const { code, json } = envelope('no_auth_method');
  assert.equal(code, 0);
  assert.equal(json.usage.userQuota.remaining, 60);
});
