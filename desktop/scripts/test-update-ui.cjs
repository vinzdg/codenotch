const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '../codenotch/ui/settings.html'), 'utf8');
const start = html.indexOf('/* ---- updates ');
const end = html.indexOf('/* ---- start ', start);
assert.ok(start >= 0 && end > start);

const calls = [];
const button = { disabled: false, textContent: '', addEventListener(_event, callback) { this.click = callback; } };
const status = { textContent: '' };
const listeners = {};
const context = vm.createContext({
  document: { getElementById: id => id === 'btn-update' ? button : status },
  ui: text => text,
  invoke: command => { calls.push(command); return Promise.resolve({}); },
  strip: error => { throw new Error(error); },
  errText: error => String(error),
  window: { __TAURI__: { event: { listen: (name, callback) => { listeners[name] = callback; } } } },
});
vm.runInContext(html.slice(start, end), context);

(async () => {
  await new Promise(setImmediate);
  assert.equal(status.textContent, '', 'unchecked must not say up to date');
  assert.equal(button.textContent, 'Check for updates');

  listeners.update_state({ payload: { available: '1.20.0', checked: true, can_install: false } });
  assert.equal(status.textContent, '1.20.0');
  assert.equal(button.textContent, 'Download installer');
  button.click();
  assert.equal(calls.at(-1), 'open_update_installer');

  context.renderUpdate({ available: '1.20.0', checked: true, can_install: true });
  assert.equal(button.textContent, 'Update');
  button.click();
  assert.equal(calls.at(-1), 'install_update');

  context.renderUpdate({ checking: true });
  assert.equal(button.disabled, true);
  assert.equal(status.textContent, 'Checking…');

  context.renderUpdate({ message: 'Could not check for updates' });
  assert.equal(button.disabled, false);
  assert.equal(status.textContent, 'Could not check for updates');
  button.click();
  assert.equal(calls.at(-1), 'check_for_update');

  context.renderUpdate({ checked: true });
  assert.equal(status.textContent, 'Up to date');
  context.renderUpdate({ available: '1.20.0', checked: true, can_install: false, message: 'Could not install the update' });
  assert.equal(status.textContent, 'Could not install the update');
  assert.equal(button.textContent, 'Download installer');
  console.log('PASS: unchecked, manual, signed, busy, error and current update states');
})().catch(error => { console.error(error); process.exitCode = 1; });
