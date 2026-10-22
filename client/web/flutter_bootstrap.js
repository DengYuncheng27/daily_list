{{flutter_js}}
{{flutter_build_config}}

// The first Flutter load must already be controlled. Registering on window.load
// is too late: CanvasKit and fonts may have loaded before a worker can cache them.
async function prepareDayflowOfflineCache() {
  if (!('serviceWorker' in navigator)) return;
  const serviceWorker = navigator.serviceWorker;
  const workerUrl = new URL('dayflow-sw.js', document.baseURI);
  const options = {scope: new URL('./', document.baseURI).pathname, updateViaCache: 'none'};

  // Offline browsers can immediately use a previously complete installation.
  // onLine=true is only a hint: network failures below also fall back safely.
  if (navigator.onLine === false &&
      serviceWorker.controller?.scriptURL === workerUrl.href) {
    return;
  }

  // Bound every phase, including register()/update() network requests. Their
  // browser-managed jobs cannot be cancelled, but late results must never add
  // listeners or start Flutter a second time after the fallback has started.
  const cancellation = new AbortController();
  const signal = cancellation.signal;
  const checkCancelled = () => {
    if (signal.aborted) throw new Error('Dayflow cache preparation was cancelled.');
  };
  const waitFor = (target, event, condition) =>
    new Promise((resolve, reject) => {
      const finish = (error) => {
        target.removeEventListener(event, check);
        signal.removeEventListener('abort', cancel);
        if (error) reject(error);
        else resolve();
      };
      const check = () => {
        try {
          checkCancelled();
          if (condition()) finish();
        } catch (error) {
          finish(error);
        }
      };
      const cancel = () => finish(new Error('Dayflow cache preparation timed out.'));
      target.addEventListener(event, check);
      signal.addEventListener('abort', cancel, {once: true});
      check();
    });

  const prepare = async () => {
    const registration = await serviceWorker.register(workerUrl, options);
    checkCancelled();
    // register() can resolve with an unchanged registration without checking
    // the server. A successful update() exposes any new installing worker.
    if (!registration.installing && !registration.waiting) {
      await registration.update();
      checkCancelled();
    }
    const worker = registration.installing || registration.waiting || registration.active;
    if (!worker || worker.scriptURL !== workerUrl.href) {
      throw new Error('Dayflow service worker is unavailable.');
    }
    await waitFor(worker, 'statechange', () => {
      if (worker.state === 'redundant') {
        throw new Error('Dayflow offline cache installation failed.');
      }
      return worker.state === 'activated';
    });
    checkCancelled();

    // Old and new versions share the same scriptURL. Match the actual worker,
    // otherwise old cached icon fonts can be mixed with the newly fetched app.
    if (serviceWorker.controller !== worker) {
      const controlled = waitFor(serviceWorker, 'controllerchange', () => {
        if (worker.state === 'redundant') {
          throw new Error('Dayflow service worker was replaced during startup.');
        }
        return serviceWorker.controller === worker;
      });
      await Promise.all([
        controlled,
        Promise.resolve().then(() => worker.postMessage({type: 'DAYFLOW_CLAIM'}))
      ]);
    }
  };

  let timeout;
  const deadline = new Promise((_, reject) => {
    timeout = setTimeout(() => {
      cancellation.abort();
      reject(new Error('Dayflow cache preparation exceeded 30 seconds.'));
    }, 30000);
  });
  try {
    await Promise.race([prepare(), deadline]);
  } finally {
    clearTimeout(timeout);
    cancellation.abort();
  }
}

(async () => {
  try {
    await prepareDayflowOfflineCache();
  } catch (error) {
    // Existing caches still work offline; storage-denied browsers can run online.
    console.warn('Dayflow cache preparation failed; using available resources.', error);
  }
  _flutter.loader.load({
    config: {canvasKitBaseUrl: new URL('canvaskit/', document.baseURI).href}
  });
})();
