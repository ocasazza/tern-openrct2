// Agent bridge: long-polls /bridge/next and answers through the wasm exports
// orct2_agent_call / orct2_load_park / orct2_advance (main thread only).
(function () {
  'use strict';

  const POLL_ABORT_MS = 40000;
  const BACKOFF_MIN_MS = 250;
  const BACKOFF_MAX_MS = 5000;
  const MAX_ADVANCE_TICKS = 1000000;

  let started = false;

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  function fail(code, message) {
    return { ok: false, error: { code: code, message: String(message) } };
  }

  function agentCall(Module, req) {
    const text = Module.ccall('orct2_agent_call', 'string', ['string'], [JSON.stringify(req)]);
    return JSON.parse(text);
  }

  function toBase64(bytes) {
    const CHUNK = 0x8000;
    let bin = '';
    for (let i = 0; i < bytes.length; i += CHUNK) {
      bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
    }
    return btoa(bin);
  }

  function handleLoad(Module, req) {
    if (typeof req.path !== 'string' || req.path === '') {
      return { ok: false, error: { code: 'invalid_args', message: 'path is required', missing: ['path'] } };
    }
    const rc = Module.ccall('orct2_load_park', 'number', ['string', 'number'], [req.path, req.asScenario ? 1 : 0]);
    if (rc !== 1) return fail('load_failed', 'could not load ' + req.path);
    const status = agentCall(Module, { v: 'status' });
    status.loaded = req.path;
    return status;
  }

  function handleAdvance(Module, req) {
    const ticks = Number(req.ticks);
    if (!Number.isInteger(ticks) || ticks < 1 || ticks > MAX_ADVANCE_TICKS) {
      return { ok: false, error: { code: 'invalid_args', message: 'ticks must be an integer in 1..' + MAX_ADVANCE_TICKS, missing: Number.isInteger(ticks) ? [] : ['ticks'] } };
    }
    const done = Module.ccall('orct2_advance', 'number', ['number'], [ticks]);
    const status = agentCall(Module, { v: 'status' });
    status.advanced = done;
    return status;
  }

  function handleScreenshot(Module, req) {
    const resp = agentCall(Module, req);
    if (!resp.ok || typeof resp.path !== 'string') return resp;
    const file = '/persistent/' + resp.path;
    try {
      resp.png_base64 = toBase64(Module.FS.readFile(file));
    } finally {
      try { Module.FS.unlink(file); } catch (e) { /* already gone */ }
    }
    return resp;
  }

  function dispatch(Module, req) {
    try {
      switch (req.v) {
        case 'load': return handleLoad(Module, req);
        case 'advance': return handleAdvance(Module, req);
        case 'screenshot': return handleScreenshot(Module, req);
        default: return agentCall(Module, req);
      }
    } catch (e) {
      return fail('exception', e && e.message ? e.message : e);
    }
  }

  async function postResult(id, resp) {
    let delay = BACKOFF_MIN_MS;
    for (let attempt = 0; attempt < 6; attempt++) {
      try {
        const r = await fetch('/bridge/result', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ id: id, resp: resp }),
        });
        if (r.ok || r.status === 404) return;
      } catch (e) { /* server down: retry */ }
      await sleep(delay);
      delay = Math.min(delay * 2, BACKOFF_MAX_MS);
    }
  }

  async function pollOnce() {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), POLL_ABORT_MS);
    try {
      const r = await fetch('/bridge/next', { cache: 'no-store', signal: ctl.signal });
      if (r.status === 204) return null;
      if (!r.ok) throw new Error('bridge/next ' + r.status);
      return await r.json();
    } finally {
      clearTimeout(timer);
    }
  }

  async function loop(Module) {
    let delay = BACKOFF_MIN_MS;
    for (;;) {
      let item;
      try {
        item = await pollOnce();
        delay = BACKOFF_MIN_MS;
      } catch (e) {
        await sleep(delay);
        delay = Math.min(delay * 2, BACKOFF_MAX_MS);
        continue;
      }
      if (!item) continue;
      await postResult(item.id, dispatch(Module, item.req || {}));
    }
  }

  window.orct2Bridge = {
    start: function (Module) {
      if (started) return;
      started = true;
      loop(Module);
    },
  };
})();
