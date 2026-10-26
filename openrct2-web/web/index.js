// Loads OpenRCT2's data and the player's RCT2 data from the loopback server into
// MEMFS, keeps saves/config/plugins in IDBFS at /persistent, then starts the game.
(async () => {
  'use strict';

  const FETCH_CONCURRENCY = 16;

  await new Promise((resolve) => window.addEventListener('DOMContentLoaded', resolve));
  const status = document.getElementById('status');
  const say = (text) => { status.textContent = text; };
  if (!window.crossOriginIsolated || !window.SharedArrayBuffer) {
    say('OpenRCT2 needs a cross-origin isolated page (COOP/COEP headers).');
    return;
  }

  const urlFor = (base, rel) => base + rel.split('/').map(encodeURIComponent).join('/');

  async function getJSON(url) {
    const res = await fetch(url, { cache: 'no-cache' });
    if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
    return res.json();
  }

  async function loadTree(Module, label, manifestUrl, base, mount) {
    const manifest = await getJSON(manifestUrl);
    const files = manifest.files;
    let done = 0;
    let next = 0;
    async function worker() {
      while (next < files.length) {
        const rel = files[next++];
        const res = await fetch(urlFor(base, rel));
        if (!res.ok) throw new Error(`${rel}: HTTP ${res.status}`);
        const bytes = new Uint8Array(await res.arrayBuffer());
        const path = `${mount}/${rel}`;
        Module.FS.mkdirTree(path.slice(0, path.lastIndexOf('/')));
        Module.FS.writeFile(path, bytes);
        done++;
        if (done % 50 === 0 || done === files.length) say(`Loading ${label}: ${done}/${files.length}`);
      }
    }
    await Promise.all(Array.from({ length: FETCH_CONCURRENCY }, worker));
  }

  await new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = 'openrct2.js';
    script.onload = resolve;
    script.onerror = () => reject(new Error('cannot load openrct2.js'));
    document.head.appendChild(script);
  });

  const canvas = document.getElementById('canvas');
  const Module = await window.OPENRCT2_WEB({
    noInitialRun: true,
    canvas: canvas,
    print: (msg) => console.log(msg),
    printErr: (msg) => console.warn(msg),
  });
  window.Module = Module;

  try {
    Module.FS.mkdir('/persistent');
    Module.FS.mount(Module.FS.filesystems.IDBFS, { autoPersist: true }, '/persistent');
    await new Promise((resolve) => Module.FS.syncfs(true, resolve));

    await loadTree(Module, 'OpenRCT2 data', 'openrct2-data/manifest.json', 'openrct2-data/', '/OpenRCT2');
    await loadTree(Module, 'RollerCoaster Tycoon 2 data', '/rct2/manifest.json', '/rct2/', '/RCT');

    const plugin = await fetch('orct2-agent.js', { cache: 'no-cache' });
    if (!plugin.ok) throw new Error(`orct2-agent.js: HTTP ${plugin.status}`);
    Module.FS.mkdirTree('/persistent/plugin');
    Module.FS.mkdirTree('/persistent/save');
    // captureImage copies this directory's attributes, so it must exist.
    Module.FS.mkdirTree('/persistent/screenshot');
    Module.FS.writeFile('/persistent/plugin/orct2-agent.js', await plugin.text());
  } catch (err) {
    console.error(err);
    say(`OpenRCT2 could not load its data: ${err.message}`);
    return;
  }

  status.remove();
  canvas.style.display = '';
  canvas.focus();
  // Audio only while the game pane has focus: an unshown Tern pane keeps the
  // page live, and a hidden page replays SDL's last buffer. The interval also
  // catches SDL creating or auto-resuming its context.
  const syncAudio = () => {
    const ctx = Module.SDL2 && Module.SDL2.audioContext;
    if (!ctx) return;
    const wanted = !document.hidden && document.hasFocus();
    if (wanted && ctx.state === 'suspended') ctx.resume();
    else if (!wanted && ctx.state === 'running') ctx.suspend();
  };
  document.addEventListener('visibilitychange', syncAudio);
  window.addEventListener('blur', syncAudio);
  window.addEventListener('focus', syncAudio);
  setInterval(syncAudio, 1000);
  // callMain enters the emscripten main loop and unwinds; nothing after it runs.
  window.orct2Bridge.start(Module);
  Module.callMain(['--user-data-path=/persistent/', '--openrct2-data-path=/OpenRCT2/']);
})();
