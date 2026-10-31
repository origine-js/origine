// `api.isolate`: the isolate capability factory. An ES module factory used by index.js:
// Its default export imports the per-realm native and shared helpers. Starts isolates on other threads. What the new isolate gets is
// `data`, the second argument of its `main`; ports (`api.host.threading.Channel`) in `data` are how it
// talks to its creator.
import { Data } from './handles.js';
import { freeze, freezeMethods, own, shared, seal } from './util.js';
class IsolateConfig extends Data {}
class IsolateOutcome extends Data {}
class IsolateHandle extends Data {}
seal(IsolateConfig, IsolateOutcome, IsolateHandle);
export default (native, { takeError }) => {
  const { ready } = shared.channels;
  const configs = new WeakSet();
  const statuses = ['running', 'completed', 'failed', 'terminated'];

  const checked = () => {
    const failed = takeError();
    if (failed !== undefined) throw failed;
  };
  const strings = (value, name) => {
    if (!Array.isArray(value) || value.some(item => typeof item !== 'string')) throw new TypeError(name + ' must be an array of strings');
    return freeze([...value]);
  };

  // The validated, frozen options of one `create`. Calling it with a config returns that config.
  function CreateConfig(options) {
    if (configs.has(options)) return options;
    const init = own(options, 'init');
    if (typeof init !== 'string' || init === '') throw new TypeError('init must be a module specifier');
    const args = strings(own(options, 'args') ?? [], 'args');
    const envOption = own(options, 'env') ?? {};
    if (envOption === null || typeof envOption !== 'object') throw new TypeError('env must be an object of strings');
    const env = {};
    for (const name of Object.keys(envOption)) {
      const value = own(envOption, name);
      if (typeof value !== 'string') throw new TypeError('env.' + name + ' must be a string');
      env[name] = value;
    }
    const snapshot = own(options, 'snapshot');
    if (snapshot !== undefined) shared.snapshotId(snapshot);
    const transfer = own(options, 'transfer');
    if (transfer !== undefined && !Array.isArray(transfer)) throw new TypeError('transfer must be an array of ArrayBuffers and ports');
    const config = new IsolateConfig({
      init,
      args,
      env: freeze(env),
      data: own(options, 'data'),
      transfer: transfer === undefined ? undefined : freeze([...transfer]),
      snapshot,
    });
    configs.add(config);
    return config;
  }

  function create(options) {
    const config = CreateConfig(options);
    ready();
    const done = native.channel.create(1);
    let data = 0;
    let id;
    try {
      // Ports and buffers listed in `transfer` move to the new isolate with `data`.
      if (config.data !== undefined) data = native.channel.stash(config.data, config.transfer);
      const env = [];
      for (const name of Object.keys(config.env)) env.push(name, config.env[name]);
      id = native.isolate.spawn(
        config.init,
        JSON.stringify(config.args),
        JSON.stringify(env),
        done.tx,
        data,
        config.snapshot === undefined ? 0 : shared.snapshotId(config.snapshot),
      );
      checked();
    } catch (error) {
      for (const handle of [done.tx, done.rx]) {
        try {
          native.channel.close(handle);
        } catch {
          // Already closed.
        }
      }
      if (data !== 0) {
        try {
          native.channel.discard(data);
        } catch {
          // Already taken.
        }
      }
      throw error;
    }
    let joined;
    const join = async () => {
      try {
        await native.channel.recv(done.rx);
      } catch (error) {
        // The `done` end closes when the thread has ended; that is the only way it ends.
        if (error === null || typeof error !== 'object' || error.name !== 'NotConnected') throw error;
      }
      try {
        native.channel.close(done.rx);
      } catch {
        // Already closed.
      }
      const status = statuses[native.isolate.outcome(id)];
      checked();
      const reason = native.isolate.failure(id);
      checked();
      return new IsolateOutcome(reason === undefined ? { status } : { status, error: reason });
    };
    return freezeMethods(
      new IsolateHandle({
        id,
        terminate() {
          native.isolate.terminate(id);
          checked();
        },
        join: () => (joined ??= join()),
      }),
    );
  }

  // The second argument of `main` in an isolate made by `create`; see `Host.run`.
  shared.initial = () => {
    const link = native.isolate.link();
    if (link === undefined || link === 0) return undefined;
    ready();
    return native.channel.unstash(link);
  };

  return () => ({ CreateConfig, create });
};
