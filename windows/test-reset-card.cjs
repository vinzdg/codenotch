const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');

const html = readFileSync(join(__dirname, 'codenotch/ui/reset-alert.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
assert.ok(script, 'the card has a script');
new vm.Script(script);

function render(overrides = {}) {
  const nodes = new Map();
  const node = id => {
    if (!nodes.has(id)) nodes.set(id, {
      textContent: '', attributes: {}, handlers: {}, style: {},
      setAttribute(name, value) { this.attributes[name] = value; },
      addEventListener(name, fn) { this.handlers[name] = fn; },
      replaceChildren(child) { this.child = child; },
    });
    return nodes.get(id);
  };
  const document = {
    documentElement: { lang: '', style: {} },
    body: { dataset: {} },
    getElementById: node,
    createElement: () => ({ src: '', alt: '' }),
    addEventListener() {},
  };
  const calls = [];
  const window = {
    __RESET_ALERT__: {
      lang: 'en', edge: 'bottom', attached: false, glyph: { kind: '', svg: '', url: '' }, token: 42,
      title: 'Codex renewed', subtitle: '5h limit renewed', status: 'Quota available · 2%', next: 'Resets in 5h', dismiss_label: 'Dismiss',
      ...overrides,
    },
    __TAURI__: { core: { invoke: (command, args) => { calls.push([command, args]); return Promise.resolve(); } } },
    addEventListener() {},
  };
  vm.runInNewContext(script, { document, window, Math, innerWidth: 280, innerHeight: 150 });
  return { node, document, calls };
}

test('the card places every already-translated string Rust hands it, verbatim', () => {
  const view = render({ title: 'Claude renovado', subtitle: 'Sessão atual renovado', status: 'Cota disponível · 2%', next: 'Renova em 5h', edge: 'bottom' });
  assert.equal(view.node('title').textContent, 'Claude renovado');
  assert.equal(view.node('subtitle').textContent, 'Sessão atual renovado');
  assert.equal(view.node('status').textContent, 'Cota disponível · 2%');
  assert.equal(view.node('next').textContent, 'Renova em 5h');
  assert.equal(view.document.body.dataset.edge, 'bottom');
});

test('no cached provider icon falls back to the title\'s own initial, not a fixed letter', () => {
  const view = render({ title: 'Cursor renewed' });
  assert.equal(view.node('glyph').textContent, 'C');
});

test('an empty next line is left out rather than shown as "Resets:" with nothing after it', () => {
  const view = render({ next: '' });
  assert.equal(view.node('next').textContent, '');
});

test('hidden notch still renders only the card and keeps an accessible dismiss control', () => {
  const view = render({ attached: false, dismiss_label: 'Dismiss' });
  assert.equal(view.document.body.dataset.attached, 'false');
  assert.equal(view.node('dismiss').attributes['aria-label'], 'Dismiss');
  view.node('dismiss').handlers.click();
  assert.equal(view.calls.length, 1);
  assert.equal(view.calls[0][0], 'dismiss_reset_alert');
  assert.equal(view.calls[0][1].token, 42);
});
