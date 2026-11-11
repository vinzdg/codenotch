/* Settings extension: the taskbar display. Status text is always rendered as text. */
(() => {
  let busy = false, taskbar = {mode:'off',supported:true};
  const el = id => document.getElementById(id);
  const t = (en, pt) => typeof uiLang !== 'undefined' && uiLang === 'pt-BR' ? pt : en;
  async function refresh(){
    try { taskbar=await invoke('get_taskbar_options')||taskbar; drawTaskbar(); }
    catch(error){ strip(errText(error)); }
  }
  function drawTaskbar(){
    if(typeof applyTaskbarAppearance==='function')applyTaskbarAppearance(taskbar.mode);
    el('taskbar-position').value=taskbar.mode;el('taskbar-position').disabled=!taskbar.supported||busy;
    const statusMessages={
      'No free space on the taskbar. Try the other side.':'Sem espaço livre na barra. Tente o outro lado.',
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
    el('taskbar-title').textContent=t('Taskbar','Barra de tarefas');el('taskbar-position-label').textContent=t('Show rings in','Mostrar os anéis em');
    const labels=[t('Notch','Notch'),t('Taskbar, left','Barra de tarefas, à esquerda'),t('Taskbar, right','Barra de tarefas, à direita')];
    [...el('taskbar-position').options].forEach((o,i)=>o.textContent=labels[i]);
    el('taskbar-help').textContent=t('On the taskbar, the rings use its free space: hover one for its card, click it to refresh, right-click for Settings. They hide when there is no room, the taskbar is hidden or an app is full screen.','Na barra de tarefas, os anéis usam o espaço livre: passe o mouse sobre um para ver o cartão, clique para atualizar e clique com o botão direito para abrir as configurações. Eles somem quando falta espaço, quando a barra está oculta ou quando um app está em tela cheia.');
  }
  async function saveTaskbar(){
    busy=true;
    try{taskbar=await invoke('set_taskbar_options',{mode:el('taskbar-position').value});toast();}
    catch(error){strip(errText(error));}
    finally{busy=false;await refresh();}
  }
  el('taskbar-position').addEventListener('change',saveTaskbar);
  window.addEventListener('focus',refresh);
  refresh();setInterval(()=>{if(!document.hidden&&!busy)refresh();},2500);
})();
