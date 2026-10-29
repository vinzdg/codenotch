/* Settings extension. Every profile label/error is rendered as text or escaped. */
(() => {
  let accounts = [], auth = {}, busy = false, lastAuthMessage = null, taskbar = {mode:'off',width:280,supported:true};
  const el = id => document.getElementById(id);
  const t = key => ui(key, key);
  let currentMessage = '', currentMessageError = false;
  const message = (value, error=false) => { currentMessage=value; currentMessageError=error; el('claude-profile-message').textContent=authMessage(value); el('claude-profile-message').dataset.error=String(error); };
  function authMessage(text){
    if(!text) return '';
    if(text.includes('CLI not found')) return t('Install the standalone Claude Code CLI to connect an account.');
    if(text.includes('Complete sign-in')) return t('Finish signing in through the browser or terminal window.');
    if(text.includes('Sign-in complete')) return t('Sign-in complete. Waiting for the usage reading…');
    if(text.includes('cancelled')) return t('Sign-in cancelled, failed or timed out. Try again.');
    return t(text);
  }
  // BEGIN TESTABLE CLAUDE ACCOUNT STATUS
  function retrySeconds(a,now=Date.now()){return Number.isFinite(a.backoff_until)&&a.backoff_until>0?Math.max(0,Math.ceil((a.backoff_until-now)/1000)):null;}
  function retryCountdown(seconds){return seconds<60?seconds+'s':Math.floor(seconds/60)+'m '+String(seconds%60).padStart(2,'0')+'s';}
  function retryTime(a,now=Date.now()){
    if(retrySeconds(a,now)==null)return '';
    const date=new Date(a.backoff_until);if(!Number.isFinite(date.getTime()))return '';
    const options={hour:'2-digit',minute:'2-digit',hour12:false};
    if(date.toDateString()!==new Date(now).toDateString()){options.day='2-digit';options.month='2-digit';}
    return new Intl.DateTimeFormat(typeof uiLang==='undefined'?'en':uiLang,options).format(date);
  }
  function stateLabel(a,now=Date.now()){
    if(!a.enabled) return t('Monitoring paused');
    if(auth.busy && auth.profile_id===a.id) return t('Signing in…');
    if(!a.connected) return t('Not connected');
    const remaining=retrySeconds(a,now);
    if(remaining>0)return t('Usage checks limited · retry in ')+retryCountdown(remaining)+' · '+retryTime(a,now);
    if(a.status==='backoff'||/^Rate limited\b/i.test(a.note||''))return t('Waiting for the next automatic usage check');
    if(a.status==='needsAuth') return t('Sign in again');
    if(a.status==='error') return t('Could not update usage');
    if(a.fetched_at && (a.status==='stale'||now-a.fetched_at>15*60*1000)) return t('Saved reading · waiting for update');
    return a.fetched_at?t('Connected'):t('Waiting for the first reading');
  }
  function stateNote(a){
    if(!a.enabled||/^Rate limited\b/i.test(a.note||''))return '';
    if(a.note==='No Claude Code credential found')return t('No Claude Code sign-in was found.');
    if(a.note==='Credential rejected (switched accounts?)')return t('Claude rejected the credential. Sign in again.');
    if(/^Credential expired\b/.test(a.note||''))return t('Claude Code sign-in expired. Reconnect this account.');
    return a.note||'';
  }
  // END TESTABLE CLAUDE ACCOUNT STATUS
  function stateMarkup(a){const note=stateNote(a);return esc(stateLabel(a))+(note?'<br>'+esc(note):'');}
  function draw(){
    const focused=document.activeElement;
    // Keep a rename intact while still advancing each account's retry countdown.
    if(focused && focused.classList.contains('profile-name')){
      for(const row of el('claude-profiles').querySelectorAll('[data-account]')){
        const a=accounts.find(account=>account.id===row.dataset.account);if(a)row.querySelector('.profile-state').innerHTML=stateMarkup(a);
      }
      return;
    }
    el('claude-profiles').innerHTML=accounts.map(a=>`<div class="profile-row" data-account="${esc(a.id)}">
      <div class="profile-top"><span class="profile-icon" aria-hidden="true">✳</span><input class="profile-name" value="${esc(a.name)}" maxlength="40" aria-label="${esc(t('Account name'))}"></div>
      <div class="profile-state">${stateMarkup(a)}</div><div class="profile-folder">${esc(a.path)}</div>
      <div class="profile-actions"><label><input class="profile-enabled" type="checkbox" ${a.enabled?'checked':''} ${busy?'disabled':''}>${esc(t('Monitor'))}</label>
      <button class="btn" data-save ${busy?'disabled':''}>${esc(t('Save name'))}</button>
      <button class="btn" data-connect ${busy||auth.busy?'disabled':''}>${esc(a.connected?t('Sign in again'):t('Connect'))}</button></div></div>`).join('');
    el('claude-add-button').disabled=busy||auth.busy;
  }
  async function refresh(){
    try {
      const values=await Promise.all([invoke('get_claude_accounts'),invoke('get_claude_auth'),invoke('get_taskbar_options')]);
      accounts=Array.isArray(values[0])?values[0]:[];auth=values[1]||{};taskbar=values[2]||taskbar;
      draw();drawTaskbar();
      if(auth.message && auth.message !== lastAuthMessage){ lastAuthMessage=auth.message; message(auth.message); }
      else if(!auth.message&&lastAuthMessage){lastAuthMessage=null;message('');}
    } catch(error){ message(errText(error),true); }
  }
  async function connect(id){
    try { await invoke('connect_claude_account',{id});message('Finish signing in through the browser.'); }
    catch(error){ message(errText(error),true); }
  }
  el('claude-add-form').addEventListener('submit',async event=>{
    event.preventDefault();if(busy||auth.busy)return;busy=true;draw();
    try { const id=await invoke('add_claude_account',{name:el('claude-account-name').value});el('claude-account-name').value='';await connect(id); }
    catch(error){message(errText(error),true);}
    finally{busy=false;await refresh();}
  });
  async function update(row){
    const id=row.dataset.account;
    await invoke('update_claude_account',{id,name:row.querySelector('.profile-name').value,enabled:row.querySelector('.profile-enabled').checked});
    toast();
  }
  el('claude-profiles').addEventListener('click',async event=>{
    const row=event.target.closest('[data-account]');if(!row||busy)return;
    if(!event.target.closest('[data-save],[data-connect]'))return;
    busy=true;
    try{if(event.target.closest('[data-connect]'))await connect(row.dataset.account);else await update(row);}
    catch(error){message(errText(error),true);}
    finally{busy=false;await refresh();}
  });
  el('claude-profiles').addEventListener('change',async event=>{
    if(!event.target.matches('.profile-enabled'))return;
    busy=true;
    try{await update(event.target.closest('[data-account]'));}
    catch(error){message(errText(error),true);}
    finally{busy=false;await refresh();}
  });
  function drawTaskbar(){
    if(typeof applyTaskbarAppearance==='function')applyTaskbarAppearance(taskbar.mode);
    el('taskbar-position').value=taskbar.mode;el('taskbar-position').disabled=!taskbar.supported||busy;
    if(document.activeElement!==el('taskbar-width'))el('taskbar-width').value=taskbar.width;
    el('taskbar-width-value').textContent=taskbar.width+' px';
    el('taskbar-width').disabled=!taskbar.supported||taskbar.mode==='off'||busy;
    const status=taskbar.status||'';
    const text=!taskbar.supported?t('Available on Windows.'):t(status);
    el('taskbar-status').hidden=!text;el('taskbar-status').textContent=text;
    el('claude-profiles-title').textContent=t('Claude accounts');
    el('claude-name-label').textContent=t('New account name');
    el('claude-add-button').textContent=t('Add account');
    el('claude-account-name').placeholder=t('Example: Work');
    el('claude-login-help').textContent=t('Each account uses the official Claude CLI sign-in in a separate folder. Switching monitoring off keeps its login.');
    el('taskbar-title').textContent=t('Taskbar');el('taskbar-position-label').textContent=t('Display');el('taskbar-width-label').textContent=t('Width');
    const labels=[t('Original notch'),t('Left side'),t('Before system tray')];
    [...el('taskbar-position').options].forEach((o,i)=>o.textContent=labels[i]);
    el('taskbar-help').textContent=t('The panel uses free space on the primary taskbar. Hover for account limits; click to refresh that account. It hides when space is unavailable, the taskbar is hidden, or an app is full screen. The system tray icon stays available.');
  }
  async function saveTaskbar(){
    busy=true;
    try{taskbar=await invoke('set_taskbar_options',{mode:el('taskbar-position').value,width:Number(el('taskbar-width').value)});toast();}
    catch(error){message(errText(error),true);}
    finally{busy=false;await refresh();}
  }
  el('taskbar-position').addEventListener('change',saveTaskbar);
  el('taskbar-width').addEventListener('input',()=>el('taskbar-width-value').textContent=el('taskbar-width').value+' px');
  el('taskbar-width').addEventListener('change',saveTaskbar);
  window.addEventListener('settings-language-changed',()=>{ draw();drawTaskbar();message(currentMessage,currentMessageError); });
  window.addEventListener('focus',refresh);
  refresh();setInterval(()=>{if(!document.hidden&&!busy)refresh();},2500);
})();
