/* Settings extension: the taskbar display. Status text is always rendered as text. */
(() => {
  let busy = false, taskbar = {mode:'off',supported:true};
  const el = id => document.getElementById(id);
  const t = (en, pt, ko) => typeof uiLang === 'undefined' ? en : uiLang === 'pt-BR' ? pt : uiLang === 'ko' ? ko : en;
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
    const koStatusMessages={
      'No free space on the taskbar. Try the other side.':'작업 표시줄에 빈 공간이 없습니다. 반대쪽을 선택해 보십시오.',
      'Windows did not expose the taskbar buttons. Use the tray to open Settings.':'Windows에서 작업 표시줄 버튼을 확인할 수 없습니다. 시계 옆 아이콘에서 설정을 여십시오.',
      'Waiting for the Windows taskbar':'Windows 작업 표시줄 대기 중',
      'Waiting for the taskbar child window':'작업 표시줄 표시 준비 중',
      'Windows taskbar accessibility is unavailable':'Windows 작업 표시줄에 접근할 수 없음',
      'Unable to create the taskbar panel':'작업 표시줄 패널을 열 수 없음',
      'Taskbar integration is unavailable because Windows DPI contexts differ. Use the tray to open Settings.':'Windows 배율 설정 때문에 작업 표시줄에 표시할 수 없습니다. 시계 옆 아이콘에서 설정을 여십시오.',
      'Windows did not expose the taskbar child window.':'Windows 작업 표시줄의 표시 영역에 접근할 수 없습니다.',
      'Unable to create the taskbar child window. Use the tray to open Settings.':'작업 표시줄에 표시할 수 없습니다. 시계 옆 아이콘에서 설정을 여십시오.',
      'Unable to schedule taskbar child creation.':'작업 표시줄 표시를 시작할 수 없습니다.'
    };
    const status=taskbar.status||'';
    const messages=t(null,statusMessages,koStatusMessages);
    const text=!taskbar.supported?t('Available on Windows.','Disponível no Windows.','Windows에서 사용할 수 있습니다.'):(messages?(messages[status]||status):status);
    el('taskbar-status').hidden=!text;el('taskbar-status').textContent=text;
    el('taskbar-title').textContent=t('Taskbar','Barra de tarefas','작업 표시줄');el('taskbar-position-label').textContent=t('Show rings in','Mostrar os anéis em','링 표시 위치');
    const labels=[t('Notch','Notch','노치'),t('Taskbar, left','Barra de tarefas, à esquerda','작업 표시줄 왼쪽'),t('Taskbar, right','Barra de tarefas, à direita','작업 표시줄 오른쪽')];
    [...el('taskbar-position').options].forEach((o,i)=>o.textContent=labels[i]);
    el('taskbar-help').textContent=t('On the taskbar, the rings use its free space: hover one for its card, click it to refresh, right-click for Settings. They hide when there is no room, the taskbar is hidden or an app is full screen.','Na barra de tarefas, os anéis usam o espaço livre: passe o mouse sobre um para ver o cartão, clique para atualizar e clique com o botão direito para abrir as configurações. Eles somem quando falta espaço, quando a barra está oculta ou quando um app está em tela cheia.','작업 표시줄에서는 링이 빈 공간에 표시됩니다. 링에 포인터를 올리면 카드가 표시되고 링을 클릭하면 측정값을 새로 고치며 마우스 오른쪽 버튼을 클릭하면 설정이 열립니다. 공간이 부족하거나 작업 표시줄이 숨겨져 있거나 앱이 전체 화면이면 링이 사라집니다.');
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
