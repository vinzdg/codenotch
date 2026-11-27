const {readFileSync} = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {test} = require('node:test');

// The card calls ui().<key>(...) for whatever it is showing, all in one renderCard. A language
// without the key threw there and left the card unopened: pt-BR had no `updated`, the line under a
// stale reading, so a stale Codex or Antigravity ring showed nothing on hover in Portuguese. A
// missing string has to fall back to English, as the Mac's catalog does, not fail.
const html = readFileSync(path.join(__dirname, '../codenotch/ui/notch.html'), 'utf8');
const source = html.slice(html.indexOf("let uiLang='en';"), html.indexOf('function setUiLanguage'));
const ctx = vm.runInNewContext(source + '; ({UI, setLang: l => { uiLang = l; }, ui})');

test('a string a language lacks falls back to English instead of throwing', () => {
  ctx.UI.xx = {locale: 'xx', title: n => 'X ' + n};
  ctx.setLang('xx');
  assert.equal(ctx.ui().title('Claude'), 'X Claude');
  assert.equal(ctx.ui().updated('5m ago'), 'Updated 5m ago');
  delete ctx.UI.xx;
});

test('every language can write the line under a stale reading', () => {
  for (const lang of Object.keys(ctx.UI)) {
    ctx.setLang(lang);
    assert.equal(typeof ctx.ui().updated(ctx.ui().ago(20)), 'string', lang);
  }
  ctx.setLang('pt-BR');
  assert.equal(ctx.ui().updated(ctx.ui().ago(20)), 'Atualizado há 20 min');
});

test('English is still English', () => {
  ctx.setLang('en');
  assert.equal(ctx.ui(), ctx.UI.en);
});
