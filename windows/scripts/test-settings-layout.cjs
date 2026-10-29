const { test } = require('node:test');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const path = require('node:path');
const { chromium } = require('playwright');

// Real browser layout with a synthetic Tauri bridge: no accounts, tokens or network providers.
test('Settings keeps translated controls reachable at Windows display scales and small work areas', async () => {
  const browser = await chromium.launch({ executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH });
  try {
    for (const deviceScaleFactor of [1, 1.25, 1.5, 2]) {
      const context = await browser.newContext({ viewport: { width: 680, height: 520 }, deviceScaleFactor });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.addInitScript(() => {
        // Language changes must redraw immediately, independently of the background poll.
        window.setInterval = () => 0;
        window.__TAURI__ = {
          core: { invoke: async cmd => ({
            get_lang: 'pt-BR', get_lang_resolved: 'pt-BR', get_theme_resolved: 'light',
            get_system_look: { mica: false, accent: [] },
            get_claude_accounts: [
              { id: 'default', name: 'Personal account with a long display name', path: 'C:\\Users\\Example\\.claude', enabled: true, connected: true },
              { id: 'work', name: 'Work', path: 'C:\\Users\\Example\\.claude-work-with-a-long-profile-folder', enabled: true, connected: false },
            ],
            get_claude_auth: { message: 'Sign-in complete' },
            get_tray_options: [], get_notch_slots: [], get_glyphs: {},
            get_taskbar_options: { mode: 'off', width: 280 },
            get_update_state: { current_version: '1.24.0', checking: false },
          })[cmd] ?? null },
          event: { listen: async () => () => {} },
          window: { getCurrentWindow: () => ({ close: async () => {} }) },
        };
      });
      await page.goto(pathToFileURL(path.join(__dirname, '../codenotch/ui/settings.html')).href);
      await page.waitForFunction(() => !document.documentElement.classList.contains('booting'));
      await page.waitForFunction(() => document.querySelectorAll('.profile-row').length === 2);
      await page.locator('#tab-appearance').click();
      for (const language of ['en', 'pt-BR', 'en', 'pt-BR', 'en']) {
        await page.locator('#lang').selectOption(language);
        await page.waitForFunction(lang => document.documentElement.lang === lang, language);
        const copy = await page.evaluate(() => ({
          title: document.getElementById('claude-profiles-title').textContent,
          add: document.getElementById('claude-add-button').textContent,
          name: document.getElementById('claude-name-label').textContent,
          placeholder: document.getElementById('claude-account-name').placeholder,
          taskbar: document.getElementById('taskbar-title').textContent,
          display: document.getElementById('taskbar-position-label').textContent,
          save: document.querySelector('[data-save]').textContent,
          state: document.querySelector('.profile-state').textContent,
          message: document.getElementById('claude-profile-message').textContent,
          accountLabel: document.querySelector('.profile-name').getAttribute('aria-label'),
        }));
        assert.deepEqual(copy, language === 'pt-BR' ? {
          title: 'Contas Claude', add: 'Adicionar conta', name: 'Nome da nova conta', placeholder: 'Ex.: Trabalho',
          taskbar: 'Barra de tarefas', display: 'Exibição', save: 'Salvar nome', state: 'Aguardando a primeira leitura',
          message: 'Login concluído. Aguardando a leitura de uso…', accountLabel: 'Nome da conta',
        } : {
          title: 'Claude accounts', add: 'Add account', name: 'New account name', placeholder: 'Example: Work',
          taskbar: 'Taskbar', display: 'Display', save: 'Save name', state: 'Waiting for the first reading',
          message: 'Sign-in complete. Waiting for the usage reading…', accountLabel: 'Account name',
        }, `switching to ${language} immediately updates static and dynamic copy without retaining the previous language`);
      }
      for (const viewport of [{ width: 680, height: 520 }, { width: 560, height: 400 }, { width: 960, height: 640 }, { width: 560, height: 328 }]) {
        await page.setViewportSize(viewport);
        for (const language of ['en', 'pt-BR', 'ru', 'es', 'ko']) {
          await page.evaluate(lang => { setUiLanguage(lang); renderAll(); }, language);
          for (const tab of ['accounts', 'appearance', 'general']) {
            await page.locator(`#tab-${tab}`).click();
            const diagnostic = `${viewport.width}x${viewport.height}, scale ${deviceScaleFactor}, ${language}, ${tab}`;
            const overflow = await page.evaluate(() => {
              const body = document.getElementById('body');
              const bounds = body.getBoundingClientRect();
              return [...body.querySelectorAll('button, select, input, .seg, .item, .profile-actions')]
                .filter(el => el.getClientRects().length)
                .filter(el => { const r = el.getBoundingClientRect(); return r.left < bounds.left - 1 || r.right > bounds.right + 1; })
                .map(el => el.id || el.className || el.tagName);
            });
            assert.deepEqual(overflow, [], diagnostic);
            const last = page.locator(`#pane-${tab} button, #pane-${tab} select, #pane-${tab} input`).filter({ visible: true }).last();
            if (await last.count()) {
              await last.scrollIntoViewIfNeeded();
              assert.equal(await last.evaluate(el => {
                const r = el.getBoundingClientRect(), b = document.getElementById('body').getBoundingClientRect();
                return r.top >= b.top - 1 && r.bottom <= b.bottom + 1;
              }), true, `last control can be scrolled into view: ${diagnostic}`);
            }
            assert.equal(await page.locator('#close').isVisible(), true, diagnostic);
          }
        }
      }
      assert.deepEqual(errors, [], 'the Settings page runs without JavaScript errors');
      await context.close();
    }
  } finally {
    await browser.close();
  }
});
