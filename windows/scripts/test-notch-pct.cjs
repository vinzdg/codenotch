const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const html=fs.readFileSync(path.join(__dirname,'../codenotch/ui/notch.html'),'utf8');
const start='// HEADLINE_PCT_START', end='// HEADLINE_PCT_END';
assert.equal(html.split(start).length,2);
assert.equal(html.split(end).length,2);
const src=html.split(start)[1].split(end)[0];
const ctx=vm.createContext({showRemaining:false,ui:()=>({usedLeft:(u,l)=>`${u}% Used · ${l}% left`,leftUsed:(l,u)=>`${l}% left · ${u}% Used`})});
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
// The meters' share: spent by default, what is left when the notch is set that way.
assert.equal(ctx.meteredFraction(0.13,false),0.13);
assert.equal(ctx.meteredFraction(0.13,true),1-0.13);
// The card line keeps both ends either way, the remaining figure leading when set; the '~' stays on the used half it qualifies.
assert.equal(ctx.usedCopy({used:0.13}),'13% Used · 87% left');
ctx.showRemaining=true;
assert.equal(ctx.usedCopy({used:0.13}),'87% left · 13% Used');
assert.equal(ctx.usedCopy({used:0.134,derived:true}),'87% left · ~13% Used');
ctx.showRemaining=false;
// Both rings and the card bar draw the metered share, clamped to what a meter can draw; colours stay on what was spent.
for(const needle of ['meteredFraction(h.used,showRemaining)','meteredFraction(wk.used,showRemaining)','meteredFraction(w.used,showRemaining)']) assert.ok(html.includes(needle),needle);
assert.equal((html.match(/meteredFraction\(/g)||[]).length,4);
// Every language's remaining-first card line, run from the table itself so a missing or misordered entry fails here.
const uiFn='function ui(){return UI[uiLang]||UI.en;}';
const uiSrc=html.slice(html.indexOf('const UI={'),html.indexOf(uiFn)+uiFn.length);
const wantLeftUsed={'ko':'87% 남음 · 13% 사용','pt-BR':'87% restante · 13% usado','en':'87% left · 13% Used','uk':'лишилось 87% · Використано 13%','ru':'осталось 87% · Использовано 13%','zh':'剩余 87% · 已用 13%','zh-Hant':'剩餘 87% · 已用 13%'};
for(const [lang,want] of Object.entries(wantLeftUsed)){
  const c=vm.createContext({});
  vm.runInContext('let uiLang='+JSON.stringify(lang)+';'+uiSrc,c);
  assert.equal(vm.runInContext("ui().leftUsed('87','13')",c),want,lang);
}
console.log('PASS: headline percentages read from either end and agree with the card');
