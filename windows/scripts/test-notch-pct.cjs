const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const html=fs.readFileSync(path.join(__dirname,'../codenotch/ui/notch.html'),'utf8');
const start='// HEADLINE_PCT_START', end='// HEADLINE_PCT_END';
assert.equal(html.split(start).length,2);
assert.equal(html.split(end).length,2);
const src=html.split(start)[1].split(end)[0];
const ctx=vm.createContext({});
vm.runInContext(src,ctx);
// The figure under the ring from either end: 12.5% spent reads 13% used, 87% left.
assert.equal(ctx.pctText(0.125),'13');
assert.equal(ctx.leftPctText(0.125),'87');
// The left half derives from the *rounded* used figure — 9.5% used is 90% left in the card,
// so the notch reads 90, not the 91 one-minus-the-fraction would give.
assert.equal(ctx.pctText(0.095),'10');
assert.equal(ctx.leftPctText(0.095),'90');
// Tenths below one percent, from either end.
assert.equal(ctx.pctText(0.003),'0.3');
assert.equal(ctx.leftPctText(0.003),'99.7');
// Spent and overspent read as nothing left, never negative.
assert.equal(ctx.leftPctText(0),'100');
assert.equal(ctx.leftPctText(1),'0');
assert.equal(ctx.leftPctText(1.28),'0');
assert.equal(ctx.pctText(1.28),'128');
// The two halves always add up outside the tenths.
for(const f of [0, 0.07, 0.125, 0.5, 0.73, 0.99, 1]){
  assert.equal(Number(ctx.pctText(f)) + Number(ctx.leftPctText(f)), 100, `used ${f}`);
}
console.log('PASS: headline percentages read from either end and agree with the card');
