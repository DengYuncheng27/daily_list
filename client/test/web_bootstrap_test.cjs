// Run from any directory: node client/test/web_bootstrap_test.cjs
// Browser APIs are mocked; this verifies ordering/failure recovery, not pixels.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

const source = fs.readFileSync(
  path.join(__dirname, '../web/flutter_bootstrap.js'), 'utf8',
).replace('{{flutter_js}}', '').replace('{{flutter_build_config}}', '');
new vm.Script(source);
const base = 'https://dayflow.test/planner/';
const workerURL = `${base}dayflow-sw.js`;

class Events {
  listeners = new Map();
  addEventListener(name, callback) {
    if (!this.listeners.has(name)) this.listeners.set(name, new Set());
    this.listeners.get(name).add(callback);
  }
  removeEventListener(name, callback) {
    this.listeners.get(name)?.delete(callback);
  }
  emit(name) {
    for (const callback of [...(this.listeners.get(name) || [])]) callback();
  }
  get listenerCount() {
    return [...this.listeners.values()].reduce((sum, set) => sum + set.size, 0);
  }
}

class Worker extends Events {
  constructor(state = 'activated') { super(); this.state = state; }
  scriptURL = workerURL;
  claims = 0;
  postMessage(message) {
    assert.equal(message.type, 'DAYFLOW_CLAIM');
    this.claims++;
  }
  transition(state) { this.state = state; this.emit('statechange'); }
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}

function environment({controller = null, online = true, supported = true} = {}) {
  const serviceWorker = new Events();
  serviceWorker.controller = controller;
  const registration = {
    installing: null, waiting: null, active: controller,
    updateCalls: 0,
    async update() { this.updateCalls++; return this; },
  };
  serviceWorker.registerCalls = 0;
  serviceWorker.register = async (url, options) => {
    serviceWorker.registerCalls++;
    assert.equal(url.href, workerURL);
    assert.equal(options.scope, '/planner/');
    assert.equal(options.updateViaCache, 'none');
    return registration;
  };
  const loads = [], warnings = [], timers = new Map();
  let nextTimer = 0;
  const globals = {
    URL, AbortController,
    document: {baseURI: base},
    navigator: supported ? {serviceWorker, onLine: online} : {},
    console: {warn: (...args) => warnings.push(args)},
    setTimeout: (callback, delay) => {
      const id = ++nextTimer;
      timers.set(id, {callback, delay});
      return id;
    },
    clearTimeout: (id) => timers.delete(id),
    _flutter: {loader: {load: (options) => {
      assert.equal(options.config.canvasKitBaseUrl, `${base}canvaskit/`);
      loads.push(serviceWorker.controller);
    }}},
  };
  return {
    serviceWorker, registration, loads, warnings, timers,
    start: () => vm.runInNewContext(source, globals),
    claim(worker) {
      serviceWorker.controller = worker;
      serviceWorker.emit('controllerchange');
    },
    expire() {
      for (const {callback, delay} of [...timers.values()]) {
        assert.equal(delay, 30000);
        callback();
      }
    },
    clean(...workers) {
      assert.equal(timers.size, 0, 'startup timers must be cleaned up');
      assert.equal(serviceWorker.listenerCount, 0, 'controller listeners must be removed');
      for (const worker of workers) assert.equal(worker.listenerCount, 0, 'state listeners must be removed');
    },
  };
}

async function tick() { for (let i = 0; i < 15; i++) await Promise.resolve(); }

test('first visit waits for both full installation and page control', async () => {
  const env = environment();
  const fresh = new Worker('installing');
  env.registration.installing = fresh;
  const done = env.start();
  await tick();
  assert.equal(env.loads.length, 0);
  assert.equal(env.registration.updateCalls, 0, 'do not interrupt an existing install');
  fresh.transition('activated');
  await tick();
  assert.equal(env.loads.length, 0, 'activation alone is not page control');
  assert.equal(fresh.claims, 1);
  env.claim(fresh);
  await done;
  assert.deepEqual(env.loads, [fresh]);
  env.clean(fresh);
});

test('online upgrade waits for the new worker despite its identical script URL', async () => {
  const old = new Worker();
  const fresh = new Worker('installing');
  const check = deferred();
  const env = environment({controller: old});
  env.registration.update = async () => {
    env.registration.updateCalls++;
    await check.promise;
    env.registration.installing = fresh;
  };
  const done = env.start();
  await tick();
  assert.equal(env.registration.updateCalls, 1);
  assert.equal(env.loads.length, 0, 'wait for the explicit online update check');
  check.resolve();
  await tick();
  assert.equal(env.loads.length, 0, 'old controller must not bypass font precache');
  fresh.transition('activated');
  await tick();
  env.serviceWorker.emit('controllerchange');
  await tick();
  assert.equal(env.loads.length, 0, 'same scriptURL on the old controller is insufficient');
  env.claim(fresh);
  await done;
  assert.deepEqual(env.loads, [fresh]);
  assert.equal(env.warnings.length, 0);
  env.clean(old, fresh);
});

test('a previously waiting upgrade is also awaited before Flutter loads', async () => {
  const old = new Worker();
  const fresh = new Worker('installed');
  const env = environment({controller: old});
  env.registration.waiting = fresh;
  const done = env.start();
  await tick();
  assert.equal(env.registration.updateCalls, 0);
  assert.equal(env.loads.length, 0);
  fresh.transition('activated');
  env.claim(fresh);
  await done;
  assert.deepEqual(env.loads, [fresh]);
  env.clean(old, fresh);
});

test('unchanged online worker is checked once and reused without waiting', async () => {
  const old = new Worker();
  const env = environment({controller: old});
  await env.start();
  assert.equal(env.registration.updateCalls, 1);
  assert.deepEqual(env.loads, [old]);
  env.clean(old);
});

test('known offline startup immediately reuses the cached worker', async () => {
  const old = new Worker();
  const env = environment({controller: old, online: false});
  await env.start();
  assert.equal(env.serviceWorker.registerCalls, 0);
  assert.deepEqual(env.loads, [old]);
  assert.equal(env.warnings.length, 0);
  env.clean(old);
});

test('network failure despite onLine=true falls back to the cached worker', async () => {
  const old = new Worker();
  const env = environment({controller: old});
  env.registration.update = async () => { throw new Error('network disconnected'); };
  await env.start();
  assert.deepEqual(env.loads, [old]);
  assert.equal(env.warnings.length, 1);
  env.clean(old);
});

test('a hung update has a bounded fallback and ignores its late completion', async () => {
  const old = new Worker();
  const fresh = new Worker('installing');
  const update = deferred();
  const env = environment({controller: old});
  env.registration.update = async () => {
    await update.promise;
    env.registration.installing = fresh;
  };
  const done = env.start();
  await tick();
  assert.equal(env.loads.length, 0);
  env.expire();
  await done;
  assert.deepEqual(env.loads, [old]);
  env.clean(old, fresh);
  update.resolve();
  await tick();
  fresh.transition('activated');
  env.claim(fresh);
  await tick();
  assert.equal(env.loads.length, 1, 'late browser jobs must not load Flutter again');
  env.clean(old, fresh);
});

test('install or claim timeout cleans listeners and keeps offline fallback usable', async () => {
  for (const state of ['installing', 'activated']) {
    const old = new Worker();
    const fresh = new Worker(state);
    const env = environment({controller: old});
    env.registration.installing = fresh;
    const done = env.start();
    await tick();
    assert.equal(env.loads.length, 0);
    env.expire();
    await done;
    assert.deepEqual(env.loads, [old]);
    env.clean(old, fresh);
  }
});

test('registration timeout and installation rejection both continue exactly once', async () => {
  const env = environment();
  env.serviceWorker.register = () => new Promise(() => {});
  const done = env.start();
  env.expire();
  await done;
  assert.equal(env.loads.length, 1);
  env.clean();

  const failed = environment();
  const worker = new Worker('installing');
  failed.registration.installing = worker;
  const failure = failed.start();
  await tick();
  worker.transition('redundant');
  await failure;
  assert.equal(failed.loads.length, 1);
  assert.equal(failed.warnings.length, 1);
  failed.clean(worker);
});

test('unsupported or storage-blocked browsers still launch the app', async () => {
  const unsupported = environment({supported: false});
  await unsupported.start();
  assert.equal(unsupported.loads.length, 1);
  unsupported.clean();
  const blocked = environment();
  blocked.serviceWorker.register = async () => { throw new Error('storage denied'); };
  await blocked.start();
  assert.equal(blocked.loads.length, 1);
  blocked.clean();
});
