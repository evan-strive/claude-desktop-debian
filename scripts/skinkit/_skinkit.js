// Skinkit — runtime CSS skin loader for Claude Desktop.
//
// Loaded after frame-fix-wrapper, before the original app entry. Reads skin
// CSS files from this directory, then injects a tiny overlay (skin picker +
// <style> tag) into every BrowserWindow's webContents on did-finish-load.

const fs = require('fs');
const path = require('path');

console.log('[Skinkit] Loaded');

const SKIN_DIR = __dirname;
const MANIFEST_PATH = path.join(SKIN_DIR, 'manifest.json');

let manifest = [];
try {
  manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
} catch (err) {
  console.error('[Skinkit] Failed to read manifest:', err);
  manifest = [];
}

const skins = manifest.map((entry) => {
  const cssPath = path.join(SKIN_DIR, entry.file);
  let css = '';
  try {
    css = fs.readFileSync(cssPath, 'utf8');
  } catch (err) {
    console.error(`[Skinkit] Failed to read ${entry.file}:`, err.message);
  }
  return { id: entry.id, name: entry.name, css };
});

console.log(`[Skinkit] Loaded ${skins.length} skin(s): ${skins.map(s => s.id).join(', ')}`);

function buildInjection(skinsJson) {
  return `
(function () {
  if (window.__skinkitInstalled) return;
  window.__skinkitInstalled = true;

  const SKINS = ${skinsJson};
  const STORAGE_KEY = 'claude-skinkit';

  const styleEl = document.createElement('style');
  styleEl.id = 'skinkit-style';
  document.head.appendChild(styleEl);

  function findSkin(id) {
    return SKINS.find(s => s.id === id) || SKINS[0];
  }

  function applySkin(id) {
    const skin = findSkin(id);
    styleEl.textContent = skin.css || '';
    try { localStorage.setItem(STORAGE_KEY, skin.id); } catch {}
    document.querySelectorAll('.skinkit-btn').forEach(b => {
      const active = b.dataset.id === skin.id;
      b.style.background = active ? '#3f3f46' : 'transparent';
      b.style.color = active ? '#f4f4f5' : '#a1a1aa';
      b.style.borderColor = active ? '#71717a' : '#3f3f46';
    });
  }

  function buildOverlay() {
    if (document.getElementById('skinkit-overlay')) return;
    const wrap = document.createElement('div');
    wrap.id = 'skinkit-overlay';
    wrap.style.cssText = [
      'position:fixed', 'bottom:8px', 'right:8px', 'z-index:2147483647',
      'display:flex', 'gap:4px', 'background:rgba(15,15,17,0.92)',
      'border:1px solid #3f3f46', 'border-radius:6px', 'padding:4px',
      'font-family:ui-monospace,"Cascadia Code",monospace',
      'font-size:11px', 'box-shadow:0 4px 12px rgba(0,0,0,0.4)',
      'backdrop-filter:blur(6px)', 'pointer-events:auto',
    ].join(';');

    const label = document.createElement('span');
    label.textContent = 'skin:';
    label.style.cssText = 'color:#71717a;padding:2px 4px;align-self:center';
    wrap.appendChild(label);

    SKINS.forEach(skin => {
      const btn = document.createElement('button');
      btn.className = 'skinkit-btn';
      btn.dataset.id = skin.id;
      btn.textContent = skin.name || skin.id;
      btn.style.cssText = [
        'background:transparent', 'color:#a1a1aa',
        'border:1px solid #3f3f46', 'border-radius:3px',
        'padding:2px 8px', 'cursor:pointer', 'font:inherit',
        'transition:all 0.15s',
      ].join(';');
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        e.preventDefault();
        applySkin(skin.id);
      });
      wrap.appendChild(btn);
    });

    document.body.appendChild(wrap);
  }

  function init() {
    if (!document.body) {
      requestAnimationFrame(init);
      return;
    }
    buildOverlay();
    let saved = 'default';
    try { saved = localStorage.getItem(STORAGE_KEY) || 'default'; } catch {}
    applySkin(saved);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  // Re-attach overlay if claude.ai's React tree wipes the body.
  const observer = new MutationObserver(() => {
    if (!document.getElementById('skinkit-overlay') && document.body) {
      buildOverlay();
      const saved = (() => { try { return localStorage.getItem(STORAGE_KEY) || 'default'; } catch { return 'default'; } })();
      applySkin(saved);
    }
  });
  if (document.body) observer.observe(document.body, { childList: true });
  else document.addEventListener('DOMContentLoaded', () => observer.observe(document.body, { childList: true }));
})();
`;
}

module.exports = function installSkinkit(electron) {
  if (!electron || !electron.app) {
    console.error('[Skinkit] No electron.app available; skipping');
    return;
  }

  const skinsJson = JSON.stringify(skins);
  const injection = buildInjection(skinsJson);

  electron.app.on('browser-window-created', (_event, win) => {
    if (!win || !win.webContents) return;

    const inject = () => {
      win.webContents.executeJavaScript(injection, true).catch((err) => {
        console.error('[Skinkit] Injection failed:', err && err.message);
      });
    };

    win.webContents.on('did-finish-load', inject);
    win.webContents.on('did-frame-finish-load', (_e, isMain) => {
      if (isMain) inject();
    });
  });

  console.log('[Skinkit] Hook installed on browser-window-created');
};
