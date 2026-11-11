// Run with node --test test-light-surface.cjs from windows/.
// Keeps all Windows pages on the same appearance contract: a light choice has a complete palette,
// SVG colours follow it, and windows that are only briefly visible get it before their first frame.
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const assert = require('node:assert/strict');
const { test } = require('node:test');

const root = __dirname;
const notch = readFileSync(join(root, 'codenotch/ui/notch.html'), 'utf8');
const settings = readFileSync(join(root, 'codenotch/ui/settings.html'), 'utf8');
const main = readFileSync(join(root, 'codenotch/src/main.rs'), 'utf8');
const settingsWindow = readFileSync(join(root, 'codenotch/src/settings_window.rs'), 'utf8');
const carry = readFileSync(join(root, 'codenotch/ui/carry.html'), 'utf8');
const carryWindow = readFileSync(join(root, 'codenotch/src/carry.rs'), 'utf8');

function cssBlock(source, selector) {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = source.match(new RegExp(`${escaped}\\s*\\{([\\s\\S]*?)\\}`));
  assert.ok(match, `missing ${selector} palette`);
  return match[1];
}

function palette(source, selector) {
  const tokens = new Map();
  for (const [, name, value] of cssBlock(source, selector).matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) {
    tokens.set(name, value.trim());
  }
  assert.ok(tokens.size > 0, `${selector} declares tokens`);
  return tokens;
}

test('light surface is a complete palette and redraws the inline SVG colours', () => {
  const dark = palette(notch, ':root');
  const light = palette(notch, ':root[data-theme="light"]');

  assert.deepEqual([...light.keys()].sort(), [...dark.keys()].sort(),
    'a token absent from light silently keeps its dark value');
  assert.deepEqual(Object.fromEntries([
    ['--pill', '#f5f5f7'],
    ['--card', '#ffffff'],
    ['--ink', '#1d1d1f'],
    ['--ink-dim', '#6b6b6b'],
    ['--ample', '#00A356'],
    ['--watch', '#B08800'],
    ['--crit', '#FF3F00'],
  ].map(([name, value]) => [name, light.get(name)])), {
    '--pill': '#f5f5f7',
    '--card': '#ffffff',
    '--ink': '#1d1d1f',
    '--ink-dim': '#6b6b6b',
    '--ample': '#00A356',
    '--watch': '#B08800',
    '--crit': '#FF3F00',
  });
  assert.notEqual(light.get('--pill'), dark.get('--pill'), 'the selected light palette is distinct');

  assert.match(notch, /function readPalette\(\)\s*\{[\s\S]*?getComputedStyle\(document\.documentElement\)[\s\S]*?--track[\s\S]*?--ample/,
    'inline SVG values are read from the active palette');
  const applyTheme = notch.match(/function applyTheme\(name\)\s*\{([\s\S]*?)\n\}/);
  assert.ok(applyTheme, 'the notch applies a resolved theme');
  assert.match(applyTheme[1], /document\.documentElement\.dataset\.theme\s*=\s*name === 'light' \? 'light' : 'dark'/);
  assert.match(applyTheme[1], /readPalette\(\);\s*renderRing\(\);/,
    'changing theme redraws the ring with the new inline colours');
  assert.match(applyTheme[1], /if\(card&&card\.classList\.contains\('show'\)\) renderCard\(\);/,
    'an open card redraws its dots too');
  assert.match(notch, /invoke\('get_theme_resolved'\)\.then\(applyTheme\)/);
  assert.match(notch, /listen\('theme_resolved',e=>applyTheme\(e\.payload\)\)/);
});

test('Settings and the carry overlay receive the same theme before either can paint', () => {
  const themeRow = settings.match(/<span class="seg" id="seg-theme">([\s\S]*?)<\/span>/);
  assert.ok(themeRow, 'Settings exposes a theme row');
  for (const choice of ['system', 'light', 'dark']) {
    assert.match(themeRow[1], new RegExp(`data-v="${choice}"`));
  }
  assert.match(settings, /:root\[data-theme="light"\]/, 'Settings has a light palette');
  assert.match(settings, /invoke\('set_theme', \{ theme: want \}\)/, 'Settings persists a choice');
  assert.match(settings, /call\('get_theme_resolved', undefined, null\)\.then\(v => \{ if\(typeof v === 'string'\) applyTheme\(v\); \}\)/,
    'Settings asks for the resolved value when it opens');

  const initialization = /\.initialization_script\(crate::theme_script\(crate::resolved_theme\(app\)\)\)/;
  assert.match(settingsWindow, initialization, 'Settings receives its theme before the first frame');
  assert.match(carryWindow, initialization, 'the carry overlay receives its theme before the first frame');
  assert.match(main, /d\.dataset\.theme=window\.__CN_THEME__/, 'the initialization script writes data-theme');
  assert.match(main, /app\.emit\("theme_resolved", resolved_theme\(app\)\)/,
    'live choices notify every open page');
});

test('the carried notch is drawn in the notch\'s own colours', () => {
  // The notch's page is empty while carry.html draws it, so a colour of its own would show as the
  // notch changing colour when it is picked up and put down
  for (const selector of [':root', ':root[data-theme="light"]']) {
    const notchPalette = palette(notch, selector);
    const carryPalette = palette(carry, selector);
    for (const [name, value] of carryPalette) {
      assert.equal(value, notchPalette.get(name), `${selector} ${name}`);
    }
  }
});
