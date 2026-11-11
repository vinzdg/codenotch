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

test('Korean card keeps numbers, plan names and unknown vendor messages', () => {
  const {textCopy, ui} = card('ko');
  assert.equal(textCopy('Current session'), '현재 세션');
  assert.equal(textCopy('Sign in'), '로그인');
  assert.equal(textCopy('Rate limited — retrying in 30s'), '요청 제한 — 30초 후 재시도');
  assert.equal(textCopy('5h limit'), '5시간 제한');
  assert.equal(textCopy('Unlimited on the Pro plan — nothing to meter'),
    'Pro 요금제는 무제한입니다 — 측정할 사용량이 없습니다');
  assert.equal(textCopy('Working in example-repo'), '작업 위치: example-repo');
  assert.equal(textCopy('New vendor message'), 'New vendor message');
  assert.equal(ui.locale, 'ko-KR');
  assert.equal(ui.usedLeft('0.6', '99.4'), '0.6% 사용 · 99.4% 남음');
  assert.equal(ui.resetsIn(51), '51분 후 재설정');
  assert.equal(ui.resetsAt('14:30'), '14:30에 재설정');
  assert.equal(ui.resetsOn('9월 28일', '14:30'), '9월 28일 14:30에 재설정');
  assert.equal(ui.ago(120), '2시간 전');
  assert.equal(ui.updated(ui.ago(20)), '20분 전에 마지막 업데이트됨');
  assert.equal(ui.andMore(3), '외 3개');
});

test('an unsupported card language still uses English', () => {
  const {textCopy, ui} = card('xx');
  assert.equal(textCopy('Current session'), 'Current session');
  assert.equal(ui.resetsIn(51), 'Resets in 51 min');
  assert.equal(ui.updated('20m ago'), 'Updated 20m ago');
});
