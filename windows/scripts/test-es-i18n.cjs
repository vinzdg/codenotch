const {readFileSync} = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {test} = require('node:test');

// Exercise the page's actual lookup and formatters without a WebView or Tauri.
const html = readFileSync(path.join(__dirname, '../codenotch/ui/notch.html'), 'utf8');
const source = html.slice(html.indexOf("let uiLang='en';"), html.indexOf('function setUiLanguage'));
function card(lang) {
  return vm.runInNewContext(source + `; uiLang=${JSON.stringify(lang)}; ({textCopy, ui:ui()})`);
}

test('Spanish card keeps numbers, plan names and unknown vendor messages', () => {
  const {textCopy, ui} = card('es');
  assert.equal(textCopy('Current session'), 'Sesión actual');
  assert.equal(textCopy('Credits'), 'Créditos');
  assert.equal(textCopy('$0.00 remaining of $2.00 · 39.1M tokens'), '$0.00 restantes de $2.00 · 39.1M tokens');
  assert.equal(textCopy('$2.00 of $2.00 used · $0.00 left · 39.1M tokens'), '$2.00 de $2.00 usados · $0.00 restantes · 39.1M tokens');
  assert.equal(textCopy('$2.00 / $2.00 USD ($0.00 left)'), '$2.00 / $2.00 USD ($0.00 restantes)');
  assert.equal(textCopy('Sign in'), 'Iniciar sesión');
  assert.equal(textCopy('Rate limited — retrying in 30s'), 'Límite de solicitudes — reintento en 30 s');
  assert.equal(textCopy('5h limit'), 'Límite de 5 h');
  assert.equal(textCopy('Unlimited on the Pro plan — nothing to meter'), 'Ilimitado en el plan Pro — nada que medir');
  assert.equal(textCopy('Working in example-repo'), 'Trabajando en example-repo');
  assert.equal(textCopy('New vendor message'), 'New vendor message');
  assert.equal(ui.locale, 'es');
  assert.equal(ui.title('Claude'), 'Uso de Claude');
  assert.equal(ui.usedLeft('0.6', '99.4'), '0.6% usado · 99.4% restante');
  assert.equal(ui.leftUsed('39', '61'), '39% restante · 61% usado');
  assert.equal(ui.andMore(3), 'y 3 más');
  assert.equal(ui.updated(ui.ago(20)), 'Actualizado hace 20 min');
});

// "Renovar", never "reiniciar": the quota renews, the app does not restart (#295). Worded as the tray
// and the Mac word it, so the three surfaces never disagree about the same reading.
test('Spanish card says a quota renews', () => {
  const {textCopy, ui} = card('es');
  assert.equal(textCopy('Resetting…'), 'Renovando…');
  assert.equal(ui.resetting, 'Renovando…');
  assert.equal(ui.resetsIn(51), 'Se renueva en 51 min');
  // A colon, not "a las": one o'clock would need "a la 1:30".
  assert.equal(ui.resetsAt('1:30'), 'Se renueva: 1:30');
  assert.equal(ui.resetsOn('jue', '14:30'), 'Se renueva el jue 14:30');
  assert.equal(ui.resetsDate('28 sept'), 'Se renueva el 28 sept');
  assert.equal(ui.ago(120), 'hace 2 h');
  for (const text of [ui.resetting, ui.resetsIn(5), ui.resetsAt('9:00'), textCopy('Resets')]) {
    assert.doesNotMatch(text, /reinici|restablec/i);
  }
});
