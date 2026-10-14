/* Settings extension. Every profile label/error is rendered as text or escaped. */
(() => {
  let accounts = [], auth = {}, busy = false, lastAuthMessage = null, taskbar = {mode:'off',width:280,supported:true};
  const el = id => document.getElementById(id);
  const t = (en, pt) => typeof uiLang !== 'undefined' && uiLang === 'pt-BR' ? pt : en;
  const message = (value, error=false) => { el('claude-profile-message').textContent=value; el('claude-profile-message').dataset.error=String(error); };
  function authMessage(text){
    if(!text) return '';
    if(text.includes('CLI not found')) return t('Install the standalone Claude Code CLI to connect an account.','Instale o Claude Code CLI para conectar uma conta.');
    if(text.includes('Complete sign-in')) return t('Finish signing in through the browser or terminal window.','Conclua o login na janela do navegador ou terminal.');
    if(text.includes('Sign-in complete')) return t('Sign-in complete. Waiting for the usage reading…','Login concluído. Aguardando a leitura de uso…');
    if(text.includes('cancelled')) return t('Sign-in cancelled, failed or timed out. Try again.','Login cancelado, não concluído ou expirado. Tente novamente.');
    return text;
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
    if(!a.enabled) return t('Monitoring paused','Monitoramento pausado');
    if(auth.busy && auth.profile_id===a.id) return t('Signing in…','Conectando…');
    if(!a.connected) return t('Not connected','Sem login');
    const remaining=retrySeconds(a,now);
    if(remaining>0)return t('Usage checks limited · retry in ','Consulta limitada · nova tentativa em ')+retryCountdown(remaining)+' · '+retryTime(a,now);
    if(a.status==='backoff'||/^Rate limited\b/i.test(a.note||''))return t('Waiting for the next automatic usage check','Aguardando a próxima consulta automática');
    if(a.status==='needsAuth') return t('Sign in again','Entre novamente');
    if(a.status==='error') return t('Could not update usage','Não foi possível atualizar o uso');
    if(a.fetched_at && (a.status==='stale'||now-a.fetched_at>15*60*1000)) return t('Saved reading · waiting for update','Leitura anterior · aguardando atualização');
    return a.fetched_at?t('Connected','Conectada'):t('Waiting for the first reading','Aguardando a primeira leitura');
  }
  function stateNote(a){
    if(!a.enabled||/^Rate limited\b/i.test(a.note||''))return '';
    if(a.note==='No Claude Code credential found')return t('No Claude Code sign-in was found.','Nenhum login do Claude Code foi encontrado.');
    if(a.note==='Credential rejected (switched accounts?)')return t('Claude rejected the credential. Sign in again.','O Claude recusou a credencial. Entre novamente.');
    if(/^Credential expired\b/.test(a.note||''))return t('Claude Code sign-in expired. Reconnect this account.','O login do Claude Code expirou. Reconecte esta conta.');
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
      <div class="profile-top"><span class="profile-icon" aria-hidden="true">✳</span><input class="profile-name" value="${esc(a.name)}" maxlength="40" aria-label="${esc(t('Account name','Nome da conta'))}"></div>
      <div class="profile-state">${stateMarkup(a)}</div><div class="profile-folder">${esc(a.path)}</div>
      <div class="profile-actions"><label><input class="profile-enabled" type="checkbox" ${a.enabled?'checked':''} ${busy?'disabled':''}>${esc(t('Monitor','Monitorar'))}</label>
      <button class="btn" data-save ${busy?'disabled':''}>${esc(t('Save name','Salvar nome'))}</button>
      <button class="btn" data-connect ${busy||auth.busy?'disabled':''}>${esc(a.connected?t('Sign in again','Entrar novamente'):t('Connect','Conectar'))}</button></div></div>`).join('');
    el('claude-add-button').disabled=busy||auth.busy;
  }
  async function refresh(){
    try {
      const values=await Promise.all([invoke('get_claude_accounts'),invoke('get_claude_auth'),invoke('get_taskbar_options')]);
      accounts=Array.isArray(values[0])?values[0]:[];auth=values[1]||{};taskbar=values[2]||taskbar;
      draw();drawTaskbar();
      if(auth.message && auth.message !== lastAuthMessage){ lastAuthMessage=auth.message; message(authMessage(auth.message)); }
      else if(!auth.message&&lastAuthMessage){lastAuthMessage=null;message('');}
    } catch(error){ message(authMessage(errText(error)),true); }
  }
  async function connect(id){
    try { await invoke('connect_claude_account',{id});message(t('Finish signing in through the browser.','Conclua o login no navegador.')); }
    catch(error){ message(authMessage(errText(error)),true); }
  }
  el('claude-add-form').addEventListener('submit',async event=>{
    event.preventDefault();if(busy||auth.busy)return;busy=true;draw();
    try { const id=await invoke('add_claude_account',{name:el('claude-account-name').value});el('claude-account-name').value='';await connect(id); }
    catch(error){message(authMessage(errText(error)),true);}
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
    catch(error){message(authMessage(errText(error)),true);}
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
    const statusMessages={
      'No free space on the taskbar. Try the other side or a smaller width.':'Sem espaço livre na barra. Tente o outro lado ou uma largura menor.',
      'Windows did not expose the taskbar buttons. Use the tray to open Settings.':'Não foi possível identificar os botões da barra. Abra as configurações pelo ícone perto do relógio.',
      'Waiting for the Windows taskbar':'Aguardando a barra de tarefas do Windows',
      'Waiting for the taskbar child window':'Preparando a exibição na barra de tarefas',
      'Windows taskbar accessibility is unavailable':'Não foi possível acessar a barra de tarefas do Windows',
      'Unable to create the taskbar panel':'Não foi possível abrir a faixa na barra de tarefas',
      'Taskbar integration is unavailable because Windows DPI contexts differ. Use the tray to open Settings.':'O Windows não permitiu a exibição na barra devido às configurações de escala. Abra as configurações pelo ícone perto do relógio.',
      'Windows did not expose the taskbar child window.':'Não foi possível acessar a exibição na barra de tarefas do Windows.',
      'Unable to create the taskbar child window. Use the tray to open Settings.':'Não foi possível abrir a exibição na barra. Abra as configurações pelo ícone perto do relógio.',
      'Unable to schedule taskbar child creation.':'Não foi possível iniciar a exibição na barra de tarefas.'
    };
    const status=taskbar.status||'';
    const text=!taskbar.supported?t('Available on Windows.','Disponível no Windows.'):(typeof uiLang!=='undefined'&&uiLang==='pt-BR'?(statusMessages[status]||status):status);
    el('taskbar-status').hidden=!text;el('taskbar-status').textContent=text;
    el('claude-profiles-title').textContent=t('Claude accounts','Contas Claude');
    el('claude-name-label').textContent=t('New account name','Nome da nova conta');
    el('claude-add-button').textContent=t('Add account','Adicionar conta');
    el('claude-account-name').placeholder=t('Example: Work','Ex.: Trabalho');
    el('claude-login-help').textContent=t('Each account uses the official Claude CLI sign-in in a separate folder. Switching monitoring off keeps its login.','Cada conta usa o login oficial do Claude CLI em uma pasta separada. Pausar o monitoramento mantém o login.');
    el('taskbar-title').textContent=t('Taskbar','Barra de tarefas');el('taskbar-position-label').textContent=t('Display','Exibição');el('taskbar-width-label').textContent=t('Width','Largura');
    const labels=[t('Original notch','Formato atual'),t('Left side','À esquerda'),t('Before system tray','Antes da bandeja')];
    [...el('taskbar-position').options].forEach((o,i)=>o.textContent=labels[i]);
    el('taskbar-help').textContent=t('The panel uses free space on the primary taskbar. Hover for account limits; click to refresh that account. It hides when space is unavailable, the taskbar is hidden, or an app is full screen. The system tray icon stays available.','A faixa ocupa espaço livre na barra principal. Passe o mouse para ver os limites; clique para atualizar aquela conta. Ela se oculta sem espaço, com a barra oculta ou em tela cheia. O ícone perto do relógio continua disponível.');
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
  window.addEventListener('focus',refresh);
  refresh();setInterval(()=>{if(!document.hidden&&!busy)refresh();},2500);
})();
