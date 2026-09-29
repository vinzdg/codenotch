const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const html=fs.readFileSync(process.argv[2]||path.join(__dirname,'../codenotch/ui/notch.html'),'utf8');
for(const [,script] of html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)) new vm.Script(script);
function block(start,end){
  assert.equal(html.split(start).length,2);
  assert.equal(html.split(end).length,2);
  return html.split(start)[1].split(end)[0];
}
const now=Date.now(), w={id:'session',used:.13,resets_at:now+3600000};
const fresh={status:'ok',fetched_at:now,windows:[w]};
const ctx=vm.createContext({Date,Math,
  staleOf:s=>s.status==='stale'||now-s.fetched_at>15*60000,
  textCopy:s=>s,resetCopy:()=> 'Future reset',
});
vm.runInContext(block('// CLAUDE_QUOTA_FRESHNESS_START','// CLAUDE_QUOTA_FRESHNESS_END'),ctx);
assert.equal(ctx.ringWindow(fresh,'claude',w),w);
assert.equal(ctx.ringWindow(fresh,'claude',null),null);
assert.equal(ctx.ringWindow(fresh,'claude',{...w,resets_at:now-1}),null);
assert.ok(ctx.ringWindow(fresh,'claude',{...w,resets_at:null}));
const unavailable=['needsAuth','stale','error','backoff','absent','none'].map(status=>({...fresh,status}));
unavailable.push({...fresh,fetched_at:now-228*3600000},{...fresh,fetched_at:0});
for(const snap of unavailable){
  assert.equal(ctx.ringWindow(snap,'claude',w),null);
  assert.equal(ctx.ringWindow(snap,'codex',w),w,'other providers remain unchanged');
  assert.match(ctx.quotaResetCopy(snap,'claude',w),/^Last reported reset:/);
}
assert.equal(ctx.quotaResetCopy(fresh,'claude',w),'Future reset');
// Execute the production ring renderer with a minimal DOM, not a duplicate renderer.
const upstream=html.includes('const wk=ringWindow');
const parts={};
for(const key of ['svg.ring','svg.reading','svg.activity','.pct','.glyph','.ringwrap','.quota-caption'])
  parts[key]={innerHTML:'',textContent:'',classList:{toggle(){}}};
const cell={querySelector:key=>parts[key]};
const p={id:'claude',base:'claude',name:'Claude',glyph:'C',snap:fresh};
Object.assign(ctx,{providers:()=>[p],glyphs:{},pill:{dataset:{cells:'claude:-'},querySelector:()=>cell},
  headlineOf:s=>s.windows[0],weeklyOf:()=>({...w,id:'weekly',resets_at:now+86400000}),
  HOLE:'#000',TRACK:'#222',INK:'#fff',WATCH:'#ff0',AMBER:'#ff0',RUNGREEN:'#0f0',
  refreshing:{},weeklyRing:'outside',workState:()=> 'idle',reportHot(){},
  svgArc:()=>'<quota-arc/>',tone:()=>'#0f0',pctText:x=>String(Math.round(x*100)),
  quotaFraction:(_,x)=>1-x,quotaPercent:(_,x)=>100-Math.round(x*100),showsRemaining:()=>true,uiLang:'en',
});
vm.runInContext(block('// QUOTA_RING_RENDER_START','// QUOTA_RING_RENDER_END'),ctx);
ctx.renderRing();
assert.match(parts[upstream?'svg.reading':'svg.ring'].innerHTML,/quota-arc/);
for(const snap of unavailable){
  p.snap=snap;ctx.renderRing();
  assert.equal(parts['.pct'].textContent,'—');
  assert.doesNotMatch(parts['svg.ring'].innerHTML,/quota-arc/,'no cached weekly/main arc');
  assert.doesNotMatch(parts['svg.reading'].innerHTML,/quota-arc/,'no cached headline arc');
}
// Secondary Claude accounts use the same freshness rule without acquiring default-account login.
if(upstream){p.id='claude@work';ctx.pill.dataset.cells='claude@work:-';p.snap=unavailable[0];ctx.renderRing();assert.equal(parts['.pct'].textContent,'—');}
p.snap=fresh;ctx.renderRing();
assert.match(parts[upstream?'svg.reading':'svg.ring'].innerHTML,/quota-arc/,'a successful refresh restores the reading');
assert.match(html,/quotaResetCopy\(snap,p\.(?:base|id),w\)/);
assert.match(html,/Last known usage — not current\./);
console.log('PASS: fresh/recovered quota, sign-out, 403-style stale cache, missing timestamps, reset expiry, weekly arcs, secondary accounts, other providers');
