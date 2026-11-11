const {readFileSync}=require('node:fs');
const {join}=require('node:path');
const vm=require('node:vm');
const {test}=require('node:test');
const assert=require('node:assert/strict');
const notch=readFileSync(join(__dirname,'codenotch/ui/notch.html'),'utf8');
function cells(usage){
  const start=notch.indexOf('function claudeCells(){');
  const end=notch.indexOf('\nfunction providers(){',start);
  assert.ok(start>=0&&end>start);
  const ctx=vm.createContext({usage});vm.runInContext(notch.slice(start,end),ctx);
  return ctx.claudeCells();
}
test('Claude account status and timestamps stay independent',()=>{
  const result=cells({status:'ok',fetched_at:500,accounts:[
    {id:'default',name:'Pessoal',status:'ok',fetched_at:500,note:'',windows:[{id:'session',used:.2}]},
    {id:'work',name:'Trabalho',status:'needsAuth',fetched_at:100,note:'Expired',windows:[{id:'session',used:.8}]}
  ]});
  assert.equal(result.length,2);assert.equal(result[0].snap.status,'ok');assert.equal(result[1].snap.status,'needsAuth');
  assert.equal(result[1].snap.fetched_at,100);assert.equal(result[1].snap.windows[0].used,.8);
  assert.equal(result[1].id,'claude@work');
});
test('Only a card among several Claude accounts says whose it is, under its title',()=>{
  const two=cells({accounts:[
    {id:'default',name:'Claude Gmail',address:'someone@gmail.com',plan:'max',status:'ok',windows:[]},
    {id:'work',name:'Claude Acme',address:'someone@acme.com',status:'ok',windows:[]},
  ]});
  assert.deepEqual(two.map(c=>c.account),['someone@gmail.com · Max','someone@acme.com']);
  assert.equal(cells({accounts:[{id:'default',name:'default',address:'someone@gmail.com',plan:'pro',status:'ok',windows:[]}]})[0].account,'');
});
test('A secondary account works when the default account is disabled',()=>{
  const result=cells({accounts:[{id:'work',name:'Trabalho',status:'ok',fetched_at:10,windows:[{id:'session',used:.6}]}]});
  assert.equal(result.length,1);assert.equal(result[0].id,'claude@work');assert.equal(result[0].snap.windows[0].id,'session');
});
test('Monitoring every Claude account can be paused',()=>assert.equal(cells({status:'absent',windows:[]}).length,0));
test('Legacy persisted readings still split into account cells',()=>{
  const result=cells({status:'ok',windows:[{id:'session',group:'default'},{id:'session@work',group:'work'}]});
  assert.equal(result.length,2);assert.equal(result[1].snap.windows[0].id,'session');
});
const panel=readFileSync(join(__dirname,'codenotch/ui/taskbar.html'),'utf8');
const panelScript=panel.match(/<script>([\s\S]*?)<\/script>/)?.[1];
assert.ok(panelScript,'the taskbar page has a script');
new vm.Script(panelScript);
function panelFns(){
  const start=panel.indexOf('function escapeHtml('),end=panel.indexOf('function renderStrip(',start);
  assert.ok(start>=0&&end>start,'the taskbar selectors can be isolated from the UI');
  const ctx=vm.createContext({lang:'pt-BR',watch:50,critical:70,tr:(_en,pt)=>pt});vm.runInContext(panel.slice(start,end),ctx);return ctx;
}
function account(provider,windows,extra={}){
  return {id:provider==='claude'?'claude@work':provider,name:provider,provider,...extra,snapshot:{status:'ok',fetched_at:Date.now(),windows}};
}
test('Both arcs select their own Claude and Codex windows regardless of API order',()=>{
  const ctx=panelFns();
  for(const [provider,sessionId,weeklyId] of [['claude','session','weekly_all'],['claude','five_hour','seven_day'],['claude','session','weekly'],['codex','primary','secondary']]){
    const item=account(provider,[{id:'seven_day_sonnet',used:.99},{id:weeklyId,label:'Weekly limit',used:.23},{id:sessionId,label:'5h limit',used:.71}]);
    assert.equal(ctx.headline(item).id,sessionId);
    assert.equal(ctx.weekly(item).id,weeklyId);
    assert.equal(ctx.displayPercent(item),23,'the number is weekly while the inside arc is 5h');
  }
});
test('An absent 5h quota never falls back to weekly or a provider headline override',()=>{
  const ctx=panelFns();
  for(const [provider,weeklyId] of [['claude','weekly_all'],['codex','secondary']]){
    const item=account(provider,[{id:weeklyId,label:'Weekly limit',used:.8}],{headline_id:weeklyId});
    assert.equal(ctx.headline(item),null);
    assert.equal(ctx.displayPercent(item),80);
  }
});
test('An absent weekly quota stays unknown rather than showing session or model quota',()=>{
  const ctx=panelFns();
  for(const provider of ['claude','codex']){
    const item=account(provider,[{id:provider==='claude'?'session':'primary',label:'5h limit',used:.57},{id:'seven_day_sonnet',used:.2},{id:'weekly_sonnet',used:.3},{id:'spark',used:.7}]);
    assert.equal(ctx.weekly(item),null);
    assert.equal(ctx.displayPercent(item),null);
  }
});
test('A real 0% weekly quota is distinct from a missing or nonpercentage quota',()=>{
  const ctx=panelFns();
  assert.equal(ctx.displayPercent(account('claude',[{id:'weekly_all',used:0}])),0);
  assert.equal(ctx.displayPercent(account('codex',[{id:'secondary',label:'Weekly limit',used:0}])),0);
  assert.equal(ctx.percent(null),null);
  assert.equal(ctx.percent({used:0,count:12}),null);
  for(const used of [undefined,null,NaN,Infinity,-Infinity,'0.8'])assert.equal(ctx.percent({used}),null);
  assert.equal(ctx.percent({used:-.2}),0);
  assert.equal(ctx.percent({used:1.2}),100);
});
test('A Codex weekly-only primary window shows its weekly percentage without inventing a 5h limit',()=>{
  const ctx=panelFns(),item=account('codex',[{id:'primary',label:'Weekly limit',used:.09}]);
  assert.equal(ctx.headline(item),null);
  assert.equal(ctx.weekly(item).id,'primary');
  assert.equal(ctx.displayPercent(item),9);
});
test('Codex window roles follow their real duration even when primary and secondary switch roles',()=>{
  const ctx=panelFns(),item=account('codex',[{id:'secondary',label:'5h limit',used:.6},{id:'primary',label:'Weekly limit',used:.09}]);
  assert.equal(ctx.headline(item).id,'secondary');
  assert.equal(ctx.weekly(item).id,'primary');
  assert.equal(ctx.displayPercent(item),9);
  assert.equal(ctx.codexWindowKind({id:'primary',windowDurationMins:10080,label:'5h limit'}),'weekly');
  assert.equal(ctx.codexWindowKind({id:'secondary',window_minutes:300,label:'Weekly limit'}),'five_hour');
  assert.equal(ctx.codexWindowKind({id:'primary',limit_window_seconds:604800}),'weekly');
});
test('Monthly and unknown Codex durations remain available in details without being called weekly or 5h',()=>{
  const ctx=panelFns();
  for(const label of ['Monthly limit','Current session','Longer window','24h limit','']){
    for(const id of ['primary','secondary']){
      const window={id,label,used:.35},item=account('codex',[window]);
      assert.equal(ctx.headline(item),null);assert.equal(ctx.weekly(item),null);
      assert.equal(ctx.displayPercent(item),null);assert.equal(ctx.weeklyWindow(window),false);
      assert.equal(ctx.windowLabel(window,item),label||id);
    }
  }
});
test('Spark and Code review quotas never replace core Codex limits even with matching durations',()=>{
  const ctx=panelFns(),item=account('codex',[{id:'spark',label:'5h limit',used:.8},{id:'spark-secondary',label:'Weekly limit',used:.7},{id:'code-review',label:'Weekly limit',used:.6}]);
  assert.equal(ctx.headline(item),null);assert.equal(ctx.weekly(item),null);assert.equal(ctx.displayPercent(item),null);
});
test('Providers with only one limit keep their normal displayed percentage',()=>{
  const ctx=panelFns();
  assert.equal(ctx.displayPercent(account('cursor',[{id:'included',used:.42},{id:'on_demand',used:.9}])),42);
  assert.equal(ctx.displayPercent(account('cursor',[{id:'on_demand',used:.9}])),null);
});
test('Work animation follows actual per-account activity instead of quota changes',()=>{
  const ctx=panelFns();
  for(const work_state of ['busy','waiting','idle']){
    assert.equal(ctx.activityState(account('claude',[{id:'session',used:.2}],{work_state})),work_state);
  }
  for(const work_state of [undefined,null,'unknown','BUSY','<img onerror="run()">']){
    assert.equal(ctx.activityState(account('codex',[{id:'primary',used:.2}],{work_state})),'idle');
  }
});
test('Old quota is visibly marked stale even while another account is fresh',()=>{
  const ctx=panelFns();assert.equal(ctx.isStale({status:'ok',fetched_at:Date.now()-16*60*1000}),true);
  assert.equal(ctx.isStale({status:'needsAuth',fetched_at:Date.now()}),true);
  assert.equal(ctx.isStale({status:'ok',fetched_at:Date.now()}),false);
});
test('Rate-limit status counts down from the deadline even when the saved reading remains ok or stale',()=>{
  const ctx=panelFns(),now=new Date(2026,9,13,16,0).getTime();
  for(const status of ['ok','stale','backoff']){
    const snapshot={status,fetched_at:now,note:'Rate limited, retrying in 480s',backoff_until:now+480000};
    assert.equal(ctx.statusText(snapshot,now),'Nova tentativa em 8m 00s');
    assert.equal(ctx.statusText(snapshot,now+32000),'Nova tentativa em 7m 28s');
    assert.match(ctx.usageNote(snapshot,now),/16:08/);
    assert.doesNotMatch(ctx.usageNote(snapshot,now),/480s/);
    assert.match(ctx.statusText(snapshot,now+480000),/Aguardando a próxima consulta/);
    assert.doesNotMatch(ctx.usageNote(snapshot,now+480000),/480s|16:08/);
    assert.equal(snapshot.backoff_until,now+480000,'UI never changes the retry deadline');
  }
});
test('Remote labels and account names cannot introduce HTML into the panel',()=>{
  const ctx=panelFns();assert.equal(ctx.escapeHtml('<img onerror="run()">'),'&lt;img onerror=&quot;run()&quot;&gt;');
  assert.equal(ctx.escapeHtml("Tom & 'Trabalho'"),'Tom &amp; &#39;Trabalho&#39;');
  assert.equal(ctx.escapeHtml(null),'');
});
test('Independent window percentages choose warning colors at the configured boundaries',()=>{
  const ctx=panelFns();
  assert.equal(ctx.color(null),'var(--muted)');
  assert.equal(ctx.color(49),'var(--good)');
  assert.equal(ctx.color(50),'var(--warn)');
  assert.equal(ctx.color(69),'var(--warn)');
  assert.equal(ctx.color(70),'var(--bad)');
});
test('Detail colours follow the legacy ramp in both themes and retain hard-step behavior',()=>{
  const ctx=panelFns();ctx.colorTransition='ramp';
  assert.equal(ctx.color(0),'rgb(0,255,136)');
  assert.equal(ctx.color(25),'rgb(121,255,68)');
  assert.equal(ctx.color(50),'rgb(242,255,0)');
  assert.equal(ctx.color(75),'rgb(249,159,0)');
  assert.equal(ctx.color(100),'rgb(255,63,0)');
  ctx.critical=90;assert.equal(ctx.color(75),'rgb(249,159,0)');
  ctx.document={documentElement:{dataset:{theme:'light'}}};
  assert.equal(ctx.color(0),'rgb(0,163,86)');
  assert.equal(ctx.color(50),'rgb(176,136,0)');
  ctx.colorTransition='hard_step';assert.equal(ctx.color(75),'var(--warn)');
});
test('Reset hints show a 5h time and a weekly weekday, date and time',()=>{
  const ctx=panelFns(),now=new Date(2026,9,13,12,0).getTime();
  const session=ctx.resetText({id:'session',resets_at:new Date(2026,9,13,16,29).getTime()},now);
  assert.match(session,/16:29/);
  assert.doesNotMatch(session,/13\/10/,'a same-day 5h reset stays concise');
  for(const id of ['weekly_all','seven_day','secondary']){
    const weekly=ctx.resetText({id,label:'Weekly limit',resets_at:new Date(2026,9,17,2,59).getTime()},now);
    assert.match(weekly,/17\/10/);
    assert.match(weekly,/02:59/);
    assert.match(weekly,/s[aá]b/i,'weekly reset includes its day of the week');
  }
  assert.doesNotMatch(String(ctx.resetText({id:'session',resets_at:'bad-date'},now)),/Invalid Date/);
  assert.equal(ctx.resetText({id:'session'},now),'');
});

// Execute the actual page script against a small DOM and a controlled timer queue.
// Only IPC is stubbed: rendering and event handlers remain the production code.
async function taskbarView(fixtures,{hover=false,selectedId=null,refreshResult=true,contentHeight=180,authState={},showsRemaining=false}={}){
  class Element{
    constructor(tag='div'){
      this.tagName=tag.toUpperCase();this.dataset={};this.style={};this.attributes={};this.handlers={};
      this.children=[];this.descendants=[];this.textContent='';this.className='';this.scrollLeft=0;
      this.classes=new Set();this.classList={toggle:(name,on)=>on?this.classes.add(name):this.classes.delete(name)};
    }
    set innerHTML(html){
      this.html=html;this.descendants=[];
      for(const [,tag,attrs,classes] of html.matchAll(/<(\w+)\b([^>]*\bclass="([^"]*)"[^>]*)>/g)){
        const child=new Element(tag);child.className=classes;child.parentElement=this;
        for(const [,name,value] of attrs.matchAll(/([\w-]+)="([^"]*)"/g))child.setAttribute(name,value);
        this.descendants.push(child);
      }
    }
    get innerHTML(){return this.html||'';}
    querySelector(selector){return this.querySelectorAll(selector)[0]||null;}
    querySelectorAll(selector){
      const classes=selector.split(',').map(s=>s.trim().replace(/^\./,''));
      return this.descendants.filter(child=>classes.some(name=>child.className.split(/\s+/).includes(name)));
    }
    replaceChildren(){this.children=[];}
    appendChild(child){child.parentElement=this;this.children.push(child);return child;}
    setAttribute(name,value){this.attributes[name]=String(value);}
    getAttribute(name){return this.attributes[name]??null;}
    addEventListener(name,handler){this.handlers[name]=handler;}
    closest(selector){return selector==='.chip'&&this.className.split(/\s+/).includes('chip')?this:this.parentElement?.closest(selector)||null;}
    contains(other){for(let node=other;node;node=node.parentElement)if(node===this)return true;return false;}
    getBoundingClientRect(){return this.bounds||{left:18,width:42};}
  }
  const nodes=new Map(),node=id=>{if(!nodes.has(id))nodes.set(id,new Element());return nodes.get(id);};
  node('details').scrollHeight=contentHeight;
  const document={
    body:node('body'),documentElement:node('html'),getElementById:node,
    querySelector:selector=>node(selector),createElement:tag=>new Element(tag),addEventListener(){},
  };
  const calls=[],events=new Map(),timers=new Map();let timerId=0,resizeCallback;
  const context=vm.createContext({
    document,devicePixelRatio:1.5,
    window:{__CODENOTCH_TASKBAR_HOVER__:hover,__CODENOTCH_TASKBAR_ITEM_ID__:selectedId,__TAURI__:{
      core:{invoke(command,args){
        calls.push({command,args});
        if(command==='get_taskbar_items')return Promise.resolve(fixtures);
        if(command==='get_claude_auth')return Promise.resolve(authState);
        if(command==='get_lang_resolved')return Promise.resolve('pt-BR');
        if(command==='get_theme_resolved')return Promise.resolve('dark');
        if(command==='get_notch_shows_remaining')return Promise.resolve(showsRemaining);
        if(command==='get_glyphs')return Promise.resolve({claude:{kind:'svg',svg:'<svg fill="currentColor"></svg>'}});
        if(command==='refresh_taskbar_item')return Promise.resolve(refreshResult);
        return Promise.resolve();
      }},
      event:{listen:(name,handler)=>{events.set(name,handler);return Promise.resolve(()=>{});}},
      window:{getCurrentWindow:()=>({close(){calls.push({command:'close_window'});}})},
    }},
    getComputedStyle:()=>({getPropertyValue:()=> '#f1f2f4'}),
    ResizeObserver:class{constructor(callback){resizeCallback=callback;}observe(){}},
    setTimeout:(fn,delay)=>{const id=++timerId;timers.set(id,{fn,delay});return id;},
    clearTimeout:id=>timers.delete(id),setInterval:()=>0,
  });
  const settle=async()=>{for(let i=0;i<20;i++)await Promise.resolve();};
  vm.runInContext(panelScript,context);await settle();
  return {
    node,calls,events,settle,
    chip:id=>node('strip').children.find(child=>child.dataset.id===id),
    dispatch:(id,event,details={})=>node(id).handlers[event]?.({target:node(id),...details}),
    async resize(height){node('details').scrollHeight=height;resizeCallback?.();await settle();},
    async tick(delay){for(const [id,timer] of [...timers])if(timer.delay<=delay){timers.delete(id);timer.fn();}await settle();},
  };
}
test('The rendered outer ring and number use weekly quota while the inner ring uses 5h',async()=>{
  const item=account('claude',[{id:'session',used:.71},{id:'weekly_all',used:.23}],{work_state:'busy'});
  const view=await taskbarView([item]),chip=view.chip(item.id);
  assert.ok(chip,'the account is rendered');
  assert.equal(chip.querySelector('.pct').textContent,'23%');
  const arcFraction=selector=>{const [arc,circumference]=chip.querySelector(selector).style.strokeDasharray.split(' ').map(Number);return arc/circumference;};
  assert.ok(Math.abs(arcFraction('.outer-progress')-.23)<1e-10);
  assert.ok(Math.abs(arcFraction('.inner-progress')-.71)<1e-10);
  assert.equal(chip.dataset.work,'busy');
  assert.match(chip.querySelector('.provider-mark').getAttribute('src'),/^data:image\/svg\+xml/);
});
test('A weekly-only Codex account renders 9% on only its outer ring with no phantom inner track',async()=>{
  const item=account('codex',[{id:'primary',label:'Weekly limit',used:.09}]),view=await taskbarView([item]),chip=view.chip(item.id);
  assert.equal(chip.querySelector('.pct').textContent,'9%');
  assert.equal(chip.querySelector('.outer-track').style.opacity,'1');
  assert.equal(chip.querySelector('.outer-progress').style.opacity,'1');
  assert.equal(chip.querySelector('.inner-track').style.opacity,'0');
  assert.equal(chip.querySelector('.inner-progress').style.opacity,'0');
});
test('Remaining mode updates both arcs and the number while keeping consumption warning colours',async()=>{
  const item=account('claude',[{id:'session',used:.71},{id:'weekly_all',used:0}]);
  const view=await taskbarView([item],{showsRemaining:true}),chip=view.chip(item.id);
  assert.equal(chip.querySelector('.pct').textContent,'100%');
  const fraction=selector=>{const [arc,circle]=chip.querySelector(selector).style.strokeDasharray.split(' ').map(Number);return arc/circle;};
  assert.equal(fraction('.outer-progress'),1);
  assert.equal(chip.querySelector('.outer-progress').style.opacity,'1');
  assert.ok(Math.abs(fraction('.inner-progress')-.29)<1e-10);
  assert.equal(chip.querySelector('.inner-progress').style.stroke,'var(--bad)');
  view.events.get('notch_shows_remaining')({payload:false});
  assert.equal(chip.querySelector('.pct').textContent,'0%');
  assert.equal(chip.querySelector('.outer-progress').style.opacity,'0');
});
test('Remaining mode also applies to detail values and bars while preserving the actual used amount',async()=>{
  const item=account('codex',[{id:'primary',label:'Weekly limit',used:.09}]);
  const view=await taskbarView([item],{hover:true,selectedId:item.id,showsRemaining:true});
  const html=view.node('cards').innerHTML;
  assert.match(html,/>91%<\/strong>/);assert.match(html,/width:91%/);
  assert.match(html,/91% restante · 9% usado/);
  assert.match(html,/Atualizado há menos de um minuto/);
});
test('Claude expired and stale quotas stay available as history without suggesting live arcs',async()=>{
  const now=Date.now(),old=account('claude',[{id:'session',used:.71,resets_at:now-1000},{id:'weekly_all',used:.23,resets_at:now+3600000}],{id:'claude@old'});
  const fresh=account('claude',[{id:'weekly_all',used:.4}],{id:'claude@fresh'});
  const view=await taskbarView([old,fresh]);
  assert.equal(view.chip(old.id).querySelector('.inner-track').style.opacity,'0');
  assert.equal(view.chip(old.id).querySelector('.pct').textContent,'23%');
  old.snapshot.fetched_at=now-16*60*1000;
  view.events.get('notch_shows_remaining')({payload:false});
  assert.equal(view.chip(old.id).querySelector('.pct').textContent,'—');
  assert.equal(view.chip(fresh.id).querySelector('.pct').textContent,'40%');
  const details=await taskbarView([old],{hover:true,selectedId:old.id});
  assert.match(details.node('cards').innerHTML,/Última renovação informada/);
  assert.match(details.node('cards').innerHTML,/Atualizado há 16 min/);
  assert.match(details.node('cards').innerHTML,/71% usado/);
});
test('Enterprise accounts with only a spend quota still have a reported percentage',()=>{
  const ctx=panelFns(),item=account('claude',[{id:'spend',label:'Spend limit',used:.31}]);
  assert.equal(ctx.headline(item).id,'spend');assert.equal(ctx.displayPercent(item),31);
});
test('Taskbar mode leaves shared appearance controls enabled, including remaining display',()=>{
  const settings=readFileSync(join(__dirname,'codenotch/ui/settings.html'),'utf8');
  const disabled=[...settings.matchAll(/<fieldset[^>]*data-notch-only[^>]*>([\s\S]*?)<\/fieldset>/g)].map(match=>match[1]).join('\n');
  for(const id of ['seg-show','sw-fullscreen','sw-adaptive','seg-edge','screen','btn-recentre'])assert.match(disabled,new RegExp('id="'+id+'"'));
  for(const id of ['sw-remaining','seg-size','seg-theme','seg-weekly','sw-weekly-dashed','seg-transition','range-watch','range-critical']){
    assert.match(settings,new RegExp('id="'+id+'"'));assert.doesNotMatch(disabled,new RegExp('id="'+id+'"'));
  }
});
test('Unknown or absent quotas do not leave tracks that suggest an available limit',async()=>{
  const item=account('codex',[{id:'primary',label:'Monthly limit',used:.35}]),view=await taskbarView([item]),chip=view.chip(item.id);
  assert.equal(chip.querySelector('.pct').textContent,'—');
  for(const selector of ['.outer-track','.outer-progress','.inner-track','.inner-progress'])assert.equal(chip.querySelector(selector).style.opacity,'0');
  const card=await taskbarView([item],{hover:true,selectedId:item.id});
  assert.match(card.node('cards').innerHTML,/Monthly limit/);assert.match(card.node('cards').innerHTML,/35%/);
});
test('Click refreshes only the chosen account and never opens the details panel',async()=>{
  const a=account('claude',[{id:'session',used:.2}],{id:'claude@pessoal'}),b=account('claude',[{id:'session',used:.6}],{id:'claude@trabalho'});
  const view=await taskbarView([a,b]);view.calls.length=0;
  view.dispatch('strip','click',{target:view.chip(b.id).querySelector('.provider-mark')});
  await view.settle();
  const refresh=view.calls.filter(call=>call.command==='refresh_taskbar_item');
  assert.equal(refresh.length,1);assert.equal(refresh[0].args.id,b.id);
  assert.equal(view.calls.some(call=>call.command==='open_taskbar_details'||call.command==='refresh_ring'),false);
});
test('Every part of an indicator refreshes the same account exactly once',async()=>{
  const a=account('claude',[],{id:'claude@pessoal'}),b=account('codex',[{id:'primary',label:'Weekly limit',used:.09}]);
  const view=await taskbarView([a,b]);
  for(const selector of [null,'.gauge','.provider-mark','.outer-track','.outer-progress','.inner-progress','.activity-arc','.pct']){
    view.calls.length=0;
    const chip=view.chip(b.id),target=selector?chip.querySelector(selector):chip;
    assert.ok(target,selector||'button padding');
    view.dispatch('strip','click',{target});await view.settle();
    const refreshed=view.calls.filter(call=>call.command==='refresh_taskbar_item');
    assert.equal(refreshed.length,1,selector||'button padding');assert.equal(refreshed[0].args.id,b.id);
    await view.tick(650);
  }
});
test('Moving across the logo, arc, percentage and padding retains one hover',async()=>{
  const item=account('claude',[]),view=await taskbarView([item]),chip=view.chip(item.id);view.calls.length=0;
  const targets=[chip.querySelector('.provider-mark'),chip.querySelector('.outer-progress'),chip.querySelector('.pct'),chip];
  view.dispatch('strip','pointerover',{target:targets[0],relatedTarget:null});
  for(let i=1;i<targets.length;i++){
    view.dispatch('strip','pointerout',{target:targets[i-1],relatedTarget:targets[i]});
    view.dispatch('strip','pointerover',{target:targets[i],relatedTarget:targets[i-1]});
  }
  await view.tick(140);
  const shown=view.calls.filter(call=>call.command==='show_taskbar_hover');
  assert.equal(shown.length,1);assert.equal(shown[0].args.id,item.id);
  assert.equal(view.calls.some(call=>call.command==='hide_taskbar_hover'),false);
});
test('A refused refresh distinguishes rate limits, authentication in progress and a missing sign-in',async()=>{
  const limited=account('claude',[]);limited.snapshot.backoff_until=Date.now()+480000;
  limited.snapshot.note='Rate limited, retrying in 480s';
  const retry=await taskbarView([limited],{hover:true,selectedId:limited.id,refreshResult:false});
  retry.dispatch('refresh','click');await retry.settle();
  assert.match(retry.node('error').textContent,/temporariamente limitada/);
  assert.doesNotMatch(retry.node('error').textContent,/login|Entre novamente/);
  assert.match(retry.node('hint').textContent,/Nova tentativa em/);
  assert.match(retry.node('cards').innerHTML,/Próxima tentativa às/);
  assert.doesNotMatch(retry.node('cards').innerHTML,/480s/);
  const authenticating=await taskbarView([limited],{hover:true,selectedId:limited.id,refreshResult:false,authState:{busy:true,profile_id:'work'}});
  authenticating.dispatch('refresh','click');await authenticating.settle();
  assert.match(authenticating.node('error').textContent,/Autenticação do Claude em andamento/);
  const signedOut=account('claude',[]);signedOut.snapshot.status='needsAuth';
  const login=await taskbarView([signedOut],{hover:true,selectedId:signedOut.id,refreshResult:false});
  login.dispatch('refresh','click');await login.settle();
  assert.equal(login.node('error').textContent,'Entre novamente nas configurações.');
});
test('Repeated clicks are coalesced for one account without blocking a different account',async()=>{
  const a=account('claude',[],{id:'claude@pessoal'}),b=account('claude',[],{id:'claude@trabalho'});
  let complete;const pending=new Promise(resolve=>complete=resolve),view=await taskbarView([a,b],{refreshResult:pending});view.calls.length=0;
  view.dispatch('strip','click',{target:view.chip(a.id)});
  view.dispatch('strip','click',{target:view.chip(a.id)});
  view.dispatch('strip','click',{target:view.chip(b.id)});
  assert.deepEqual(view.calls.filter(call=>call.command==='refresh_taskbar_item').map(call=>call.args.id),[a.id,b.id]);
  complete(true);await view.settle();await view.tick(650);
  view.dispatch('strip','click',{target:view.chip(a.id)});await view.settle();
  assert.equal(view.calls.filter(call=>call.command==='refresh_taskbar_item').length,3);
});
test('Hover selects the chosen account and reports its anchor in physical pixels',async()=>{
  const item=account('claude',[]),view=await taskbarView([item]),chip=view.chip(item.id);view.calls.length=0;
  chip.bounds={left:24,width:40};
  view.dispatch('strip','pointerover',{target:chip.querySelector('.provider-mark'),relatedTarget:null});
  assert.equal(view.calls.some(call=>call.command==='show_taskbar_hover'),false,'hover waits briefly to avoid flicker');
  await view.tick(140);
  const shown=view.calls.find(call=>call.command==='show_taskbar_hover');
  assert.ok(shown);assert.equal(shown.args.id,item.id);assert.equal(shown.args.anchorX,36);assert.equal(shown.args.anchorWidth,60);
});
test('Leaving before the hover delay cancels the card without confusing another account',async()=>{
  const a=account('claude',[],{id:'claude@pessoal'}),b=account('claude',[],{id:'claude@trabalho'}),view=await taskbarView([a,b]);view.calls.length=0;
  view.dispatch('strip','pointerover',{target:view.chip(a.id)});
  view.dispatch('strip','pointerout',{target:view.chip(a.id),relatedTarget:view.chip(b.id)});
  view.dispatch('strip','pointerover',{target:view.chip(b.id),relatedTarget:view.chip(a.id)});
  await view.tick(140);
  const shown=view.calls.filter(call=>call.command==='show_taskbar_hover');
  assert.equal(shown.length,1);assert.equal(shown[0].args.id,b.id);
  view.calls.length=0;
  view.dispatch('strip','pointerover',{target:view.chip(a.id)});
  view.dispatch('strip','pointerout',{target:view.chip(a.id),relatedTarget:null});
  await view.tick(140);
  assert.equal(view.calls.some(call=>call.command==='show_taskbar_hover'),false);
  assert.equal(view.calls.some(call=>call.command==='hide_taskbar_hover'),true);
});
test('Moving inside an indicator does not hide its card; entering the card holds it open',async()=>{
  const item=account('claude',[]),view=await taskbarView([item]),chip=view.chip(item.id);view.calls.length=0;
  view.dispatch('strip','pointerout',{target:chip.querySelector('.provider-mark'),relatedTarget:chip.querySelector('.pct')});
  assert.equal(view.calls.length,0);
  const card=await taskbarView([item],{hover:true,selectedId:item.id});card.calls.length=0;
  card.dispatch('body','pointerenter');card.dispatch('body','pointerleave');
  const held=card.calls.filter(call=>call.command==='hold_taskbar_hover');
  assert.equal(held.length,2);assert.equal(held[0].args.held,true);assert.equal(held[1].args.held,false);
});
test('A hovered card shows only that account and escapes remote names and notes at rendering',async()=>{
  const a=account('claude',[],{id:'claude@pessoal',name:'Conta pessoal'});
  const b=account('claude',[{id:'custom',label:'<img src=x onerror="run()">',used:.6}],{id:'claude@trabalho',name:'<img onerror="run()">'});
  b.snapshot.note='<script>run()</script>';
  const view=await taskbarView([a,b],{hover:true,selectedId:b.id}),html=view.node('cards').innerHTML;
  assert.doesNotMatch(html,/Conta pessoal/);
  assert.doesNotMatch(html,/<img|<script/);
  assert.match(html,/&lt;img/);assert.match(html,/&lt;script&gt;run\(\)&lt;\/script&gt;/);
  assert.match(html,/60%/);
});
test('Hover reports its natural content height and resizes only when its content size changes',async()=>{
  const item=account('codex',[{id:'primary',label:'Weekly limit',used:.09}]);
  const view=await taskbarView([item],{hover:true,selectedId:item.id,contentHeight:168});
  const sizes=()=>view.calls.filter(call=>call.command==='report_taskbar_hover_size');
  assert.equal(sizes().length,1);assert.equal(sizes()[0].args.id,item.id);
  assert.equal(sizes()[0].args.height,170);assert.equal(sizes()[0].args.dpr,1.5);
  await view.resize(168);assert.equal(sizes().length,1,'unchanged content does not cause a resize loop');
  await view.resize(124);assert.equal(sizes().length,2);assert.equal(sizes()[1].args.height,126);
  const strip=await taskbarView([item]);assert.equal(strip.calls.some(call=>call.command==='report_taskbar_hover_size'),false);
});
const accountSettings=readFileSync(join(__dirname,'codenotch/ui/accounts-taskbar.js'),'utf8');
const settingsPage=readFileSync(join(__dirname,'codenotch/ui/settings.html'),'utf8');
function claudeRowFns(claudeAuth={}){
  const begin='// BEGIN TESTABLE CLAUDE ROW',end='// END TESTABLE CLAUDE ROW';
  assert.equal(settingsPage.split(begin).length,2);assert.equal(settingsPage.split(end).length,2);
  const words={needsAuth:'not signed in',stale:'last reading is old',ok:''};
  const ctx=vm.createContext({claudeAuth,SIGNING_IN:'Finish signing in',ui:(_key,fallback)=>fallback,statusText:p=>words[p.status]??''});
  vm.runInContext(settingsPage.split(begin)[1].split(end)[0],ctx);return ctx;
}
test('A Claude account row says who it is, and what it needs only while it is on',()=>{
  const ctx=claudeRowFns();
  const a={id:'work',address:'me@acme.com',connected:true,status:'ok'};
  assert.equal(ctx.claudeDetail(a,true),'me@acme.com');
  assert.equal(ctx.claudeDetail({...a,status:'stale'},true),'me@acme.com · last reading is old');
  assert.equal(ctx.claudeDetail({...a,status:'needsAuth'},true),'not signed in');
  assert.equal(ctx.claudeDetail({...a,connected:false,address:null},true),'not signed in');
  assert.equal(ctx.claudeDetail({...a,status:'needsAuth'},false),'me@acme.com','a switched-off account is not read, so it claims nothing about its sign-in');
  assert.equal(claudeRowFns({busy:true,profile_id:'other'}).claudeDetail({...a,connected:false},true),'not signed in');
});
test('A sign-in in progress counts down to the moment it is given up on',()=>{
  const now=1_800_000_000_000,signing=claudeRowFns({busy:true,profile_id:'2',deadline:now+245_000});
  const added={id:'2',address:null,connected:false,status:'needsAuth'};
  assert.equal(signing.claudeDetail(added,true,now),'Finish signing in · 4:05');
  assert.equal(signing.claudeDetail(added,true,now+244_100),'Finish signing in · 0:01');
  assert.equal(signing.claudeDetail(added,true,now+245_000),'Finish signing in','no 0:00 or negative time once it is due');
  assert.equal(claudeRowFns({busy:true,profile_id:'2'}).claudeDetail(added,true,now),'Finish signing in');
});
test('Claude accounts are rows in the provider list, not a block of their own',()=>{
  assert.doesNotMatch(settingsPage,/claude-profiles|claude-add-form|profile-name/);
  assert.doesNotMatch(accountSettings,/claude|profile/i);
});
async function settingsView(status=''){
  const nodes=new Map(),node=id=>{
    if(!nodes.has(id))nodes.set(id,{dataset:{},options:[{},{},{}],innerHTML:'',textContent:'',value:'',classList:{contains:()=>false},addEventListener(){}});
    return nodes.get(id);
  };
  const ctx=vm.createContext({
    document:{getElementById:node,activeElement:null,hidden:false},window:{addEventListener(){}},uiLang:'pt-BR',
    errText:String,toast(){},strip(){},setInterval(){},
    invoke:async command=>command==='get_taskbar_options'?{mode:'off',supported:true,status}:undefined,
  });
  vm.runInContext(accountSettings,ctx);for(let i=0;i<20;i++)await Promise.resolve();return node;
}
test('Taskbar integration failures use Portuguese without showing implementation terms in Settings',async()=>{
  for(const status of ['Taskbar integration is unavailable because Windows DPI contexts differ. Use the tray to open Settings.','Windows did not expose the taskbar child window.','Unable to create the taskbar child window. Use the tray to open Settings.','Unable to schedule taskbar child creation.','Waiting for the taskbar child window']){
    const node=await settingsView(status);
    assert.notEqual(node('taskbar-status').textContent,status);assert.doesNotMatch(node('taskbar-status').textContent,/DPI|child/i);
  }
  const normal=await settingsView();assert.equal(normal('taskbar-status').hidden,true);
});
