/* Settings extension: the taskbar display. Status text is always rendered as text. */
(() => {
  let busy = false, taskbar = {mode:'off',width:280,supported:true};
  const el = id => document.getElementById(id);
  const t = (en, pt) => typeof uiLang !== 'undefined' && uiLang === 'pt-BR' ? pt : en;
  async function refresh(){
    try { taskbar=await invoke('get_taskbar_options')||taskbar; drawTaskbar(); }
    catch(error){ strip(errText(error)); }
  }
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
    el('taskbar-title').textContent=t('Taskbar','Barra de tarefas');el('taskbar-position-label').textContent=t('Display','Exibição');el('taskbar-width-label').textContent=t('Width','Largura');
    const labels=[t('Original notch','Formato atual'),t('Left side','À esquerda'),t('Before system tray','Antes da bandeja')];
    [...el('taskbar-position').options].forEach((o,i)=>o.textContent=labels[i]);
    el('taskbar-help').textContent=t('The panel uses free space on the primary taskbar. Hover for account limits; click to refresh that account. It hides when space is unavailable, the taskbar is hidden, or an app is full screen. The system tray icon stays available.','A faixa ocupa espaço livre na barra principal. Passe o mouse para ver os limites; clique para atualizar aquela conta. Ela se oculta sem espaço, com a barra oculta ou em tela cheia. O ícone perto do relógio continua disponível.');
  }
  async function saveTaskbar(){
    busy=true;
    try{taskbar=await invoke('set_taskbar_options',{mode:el('taskbar-position').value,width:Number(el('taskbar-width').value)});toast();}
    catch(error){strip(errText(error));}
    finally{busy=false;await refresh();}
  }
  el('taskbar-position').addEventListener('change',saveTaskbar);
  el('taskbar-width').addEventListener('input',()=>el('taskbar-width-value').textContent=el('taskbar-width').value+' px');
  el('taskbar-width').addEventListener('change',saveTaskbar);
  window.addEventListener('focus',refresh);
  refresh();setInterval(()=>{if(!document.hidden&&!busy)refresh();},2500);
})();
