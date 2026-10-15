const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');

const html = readFileSync(join(__dirname, 'codenotch/ui/notch.html'), 'utf8');
const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)];
assert.equal(scripts.length, 1, 'the notch has one script');
const script = scripts[0][1];

function sourceOf(pattern, name) {
  const matches = [...script.matchAll(pattern)];
  assert.equal(matches.length, 1, `exactly one ${name}`);
  return matches[0][0];
}
function functionSource(name) {
  return sourceOf(new RegExp(`^function ${name}\\([^\\n]*\\{(?:[^\\n]*\\}|[\\s\\S]*?^\\})`, 'gm'), name);
}
const dictionaries = ['TEXT', 'PATTERNS', 'UI'].map(name =>
  sourceOf(new RegExp(`^const ${name}=\\{[\\s\\S]*?^\\};`, 'gm'), name));
// Include late dictionary assignments too, so Japanese is tested as the page actually uses it.
const assignments = [...script.matchAll(/^(?:TEXT|PATTERNS|UI)\.[a-z]+\s*=\s*\{[\s\S]*?\};/gm)];
const functions = ['smallPct', 'deficitOf', 'usedHalves', 'usedCopy', 'ui', 'setUiLanguage'].map(functionSource);
const pureSource = ["let uiLang='en', showRemaining=false;", ...dictionaries, ...assignments.map(m => m[0]), ...functions].join('\n');
const NOW = 1_800_000_000_000;
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const FIVE_HOURS = 5 * HOUR;
const WEEK = 7 * DAY;

function page(lang = 'en') {
  const context = vm.createContext({ Date: class extends Date { static now() { return NOW; } },
    card: null, renderRing() {} });
  vm.runInContext(pureSource, context);
  context.setUiLanguage(lang);
  return context;
}
function windowOf(overrides = {}) {
  return { used: 0.6, duration_ms: FIVE_HOURS, resets_at: NOW + 2.5 * HOUR, ...overrides };
}

const workedExamples = [
  ['under pace', 0.1, 2.5 * HOUR, null, '10% Used · 90% left'],
  ['on pace', 0.5, 2.5 * HOUR, null, '50% Used · 50% left'],
  ['ten points ahead', 0.6, 2.5 * HOUR, '10', '60% Used · 40% left · 10% deficit'],
  ['forty points ahead', 0.7, 3.5 * HOUR, '40', '70% Used · 30% left · 40% deficit'],
  ['fractional points', 0.625, 2.5 * HOUR, '12.5', '63% Used · 37% left · 12.5% deficit'],
  ['sub-tenth deficit', 0.5004, 2.5 * HOUR, '<0.1', '50% Used · 50% left · <0.1% deficit'],
  ['exhausted allowance', 1, 4 * HOUR, '80', '100% Used · 0% left · 80% deficit'],
  ['clock skew', 0.3, 6 * HOUR, '30', '30% Used · 70% left · 30% deficit'],
];

test('the entire notch script compiles, including code outside the extracted helpers', () => {
  assert.doesNotThrow(() => new vm.Script(script, { filename: 'notch.html' }));
});
for (const [name, used, remaining, deficit, copy] of workedExamples) {
  test(`worked example: ${name}`, () => {
    const view = page();
    const w = windowOf({ used, resets_at: NOW + remaining });
    assert.equal(view.deficitOf(w), deficit);
    assert.equal(view.usedCopy(w), copy);
  });
}

test('Mac weekly deficit, reserve, arbitrary duration and just-beyond-cycle cases', () => {
  const view = page();
  const cases = [
    [windowOf({ used: 0.98, duration_ms: WEEK, resets_at: NOW + DAY }), '12.3', '98% Used · 2% left · 12.3% deficit'],
    [windowOf({ used: 0.27, duration_ms: WEEK, resets_at: NOW + WEEK / 2 }), null, '27% Used · 73% left'],
    [windowOf({ used: 0.8, duration_ms: 3 * DAY, resets_at: NOW + 36 * HOUR }), '30', '80% Used · 20% left · 30% deficit'],
    [windowOf({ used: 0.2, duration_ms: WEEK, resets_at: NOW + WEEK + 1000 }), '20', '20% Used · 80% left · 20% deficit'],
    [windowOf({ used: 0.4996 }), null, '50% Used · 50% left'],
    [windowOf({ used: 0 }), null, '0% Used · 100% left'],
  ];
  for (const [w, deficit, copy] of cases) {
    assert.equal(view.deficitOf(w), deficit);
    assert.equal(view.usedCopy(w), copy);
  }
});

test('invalid or unknown windows cannot produce a deficit', () => {
  const view = page();
  const invalid = [
    ...[undefined, null, NaN, Infinity, -Infinity, -0.1, '0.6'].map(used => ({ used })),
    ...[undefined, null, 0, -1, NaN, Infinity, -Infinity, '18000000'].map(duration_ms => ({ duration_ms })),
    ...[undefined, null, 0, NOW, NOW - 1, NaN, Infinity, -Infinity, String(NOW + HOUR)].map(resets_at => ({ resets_at })),
    ...[0, 1, 42].map(count => ({ count })),
  ];
  for (const overrides of invalid) {
    assert.equal(view.deficitOf(windowOf(overrides)), null, JSON.stringify(overrides));
  }
  for (const count of [undefined, null]) assert.equal(view.deficitOf(windowOf({ count })), '10');
});

test('legacy windows, count windows and elapsed resets keep their used/left copy', () => {
  const view = page();
  const archived = JSON.parse('{"used":0.6,"resets_at":1800009000000}');
  assert.equal(view.deficitOf(archived), null);
  assert.equal(view.usedCopy(archived), '60% Used · 40% left');
  for (const overrides of [{ duration_ms: null }, { duration_ms: 0 }, { resets_at: null },
    { resets_at: NOW }, { resets_at: NOW - 1 }, { count: 0 }, { count: 42 }]) {
    assert.equal(view.usedCopy(windowOf(overrides)), '60% Used · 40% left');
  }
});

test('spent share caps at 100% without changing the original used reading', () => {
  const view = page();
  for (const used of [1, 1.2, Number.MAX_VALUE]) {
    assert.equal(view.deficitOf(windowOf({ used, resets_at: NOW + 4 * HOUR })), '80');
  }
  assert.equal(view.usedCopy(windowOf({ used: 1.2, resets_at: NOW + 4 * HOUR })), '120% Used · 0% left · 80% deficit');
  assert.equal(view.deficitOf(windowOf({ used: 1, resets_at: NOW + 1 })), '<0.1');
});

test('no elapsed floor, early rounding, or minimum deficit hides positive usage pace', () => {
  const view = page();
  assert.equal(view.deficitOf(windowOf({ used: 0.1, resets_at: NOW + FIVE_HOURS * 0.99 })), '9');
  assert.equal(view.deficitOf(windowOf({ used: 0.2, resets_at: NOW + FIVE_HOURS })), '20');
  assert.equal(view.deficitOf(windowOf({ used: 0.50049 })), '<0.1');
  assert.equal(view.deficitOf(windowOf({ used: 0.50051 })), '0.1');
  assert.equal(view.deficitOf(windowOf({ used: 0.6006 })), '10.1');
});

test('each calculation reads the current clock rather than a cached time', () => {
  const view = page();
  const w = windowOf();
  assert.equal(view.deficitOf(w), '10');
  view.Date.now = () => NOW + HOUR;
  assert.equal(view.deficitOf(w), null);
  assert.equal(view.usedCopy(w), '60% Used · 40% left');
});

const translations = [
  ['en', '10% deficit', '12.5% deficit', '<0.1% deficit', '63% Used · 37% left · 12.5% deficit'],
  ['pt-BR', '10% de déficit', '12.5% de déficit', '<0.1% de déficit', '63% usado · 37% restante · 12.5% de déficit'],
  ['ru', 'дефицит 10%', 'дефицит 12.5%', 'дефицит <0.1%', 'Использовано 63% · осталось 37% · дефицит 12.5%'],
  ['zh', '10% 透支', '12.5% 透支', '<0.1% 透支', '已用 63% · 剩余 37% · 12.5% 透支'],
  ['zh-Hant', '10% 透支', '12.5% 透支', '<0.1% 透支', '已用 63% · 剩餘 37% · 12.5% 透支'],
  ['ja', '10% 超過', '12.5% 超過', '<0.1% 超過', '63% Used · 37% left · 12.5% 超過'],
  ['uk', '10% дефіциту', '12.5% дефіциту', '<0.1% дефіциту', 'Використано 63% · лишилось 37% · 12.5% дефіциту'],
  ['ko', '10% 초과', '12.5% 초과', '<0.1% 초과', '63% 사용 · 37% 남음 · 12.5% 초과'],
];
for (const [lang, whole, decimal, tiny, copy] of translations) {
  test(`${lang}: literal deficit wording and dot decimals in the actual UI`, () => {
    const view = page(lang);
    assert.equal(vm.runInContext('uiLang', view), lang);
    assert.equal(view.ui().deficit('10'), whole);
    assert.equal(view.ui().deficit('12.5'), decimal);
    assert.equal(view.ui().deficit('<0.1'), tiny);
    assert.equal(view.usedCopy(windowOf({ used: 0.625 })), copy);
    assert.equal(view.usedCopy(windowOf()), view.ui().usedLeft('60', '40') + ' · ' + whole);
    assert.equal(view.usedCopy(windowOf({ used: 0.5004 })), view.ui().usedLeft('50', '50') + ' · ' + tiny);
    assert.equal(view.usedCopy(windowOf({ used: 0.27 })), view.ui().usedLeft('27', '73'));
    assert.equal(view.usedCopy(windowOf({ used: 0.5 })), view.ui().usedLeft('50', '50'));
    assert.equal(view.usedCopy(windowOf({ duration_ms: undefined })), view.ui().usedLeft('60', '40'));
  });
}

test('English and Russian append after used/left and preserve derived readings', () => {
  const en = page(), ru = page('ru');
  assert.equal(en.usedCopy(windowOf()), '60% Used · 40% left · 10% deficit');
  assert.equal(ru.usedCopy(windowOf()), 'Использовано 60% · осталось 40% · дефицит 10%');
  assert.equal(en.usedCopy(windowOf({ derived: true })), '~60% Used · 40% left · 10% deficit');
  assert.equal(ru.usedCopy(windowOf({ derived: true })), 'Использовано ~60% · осталось 40% · дефицит 10%');
  assert.equal(en.usedCopy(windowOf({ used: 0.1, derived: true })), '~10% Used · 90% left');
  assert.equal(en.usedCopy(windowOf({ used: 0.0004, derived: true, resets_at: NOW + FIVE_HOURS })), '~<0.1% Used · >99.9% left · <0.1% deficit');
  assert.equal(en.usedCopy(windowOf({ used: 0.9996, derived: true })), '~>99.9% Used · <0.1% left · 50% deficit');
});

test('unknown languages retain the English fallback', () => {
  assert.equal(page('unknown').usedCopy(windowOf()), '60% Used · 40% left · 10% deficit');
});

test('all deficit translations match the Mac Localizable entry', () => {
  const catalog = JSON.parse(readFileSync(join(__dirname, '../Sources/Localizable.xcstrings'), 'utf8'));
  const entry = catalog.strings['%@%% deficit'];
  assert.ok(entry, 'the Mac deficit localization exists');
  for (const [lang, , expected] of translations) {
    const macLang = lang === 'zh' ? 'zh-Hans' : lang;
    const template = lang === 'en' ? '%@%% deficit' : entry.localizations[macLang].stringUnit.value;
    assert.equal(template.replace('%@', '12.5').replace('%%', '%'), expected, lang);
    assert.equal(page(lang).ui().deficit('12.5'), expected, lang);
  }
});
