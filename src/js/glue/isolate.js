// `api.isolate`: the isolate capability factory. Evaluated as an expression by src/api/glue.zig:
// `(native, util) => makeIsolateCap`. Starts isolates on other threads and connects them to this one
// with channels (`api.host.threading`, whose pieces `host.js` publishes in `util.shared.channels`).
(native, { freeze, freezeMethods, own, shared, take, failure }) => {
  const { ready, makeSender, makeReceiver } = shared.channels;
  const configs = new WeakSet();
  const statuses = ['running', 'completed', 'failed', 'terminated'];

  const checked = code => {
    if (code !== 0) throw failure(code);
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
    const capacity = own(options, 'capacity');
    if (!Number.isInteger(capacity) || capacity < 1 || capacity > 0xffffffff) {
      throw new TypeError('capacity must be an integer from 1 to 2^32 - 1');
    }
    const args = strings(own(options, 'args') ?? [], 'args');
    const envOption = own(options, 'env') ?? {};
    if (envOption === null || typeof envOption !== 'object') throw new TypeError('env must be an object of strings');
    const env = {};
    for (const name of Object.keys(envOption)) {
      const value = own(envOption, name);
      if (typeof value !== 'string') throw new TypeError('env.' + name + ' must be a string');
      env[name] = value;
    }
    const transfer = own(options, 'transfer');
    if (transfer !== undefined && !Array.isArray(transfer)) throw new TypeError('transfer must be an array of ArrayBuffers');
    const config = freeze({
      init,
      capacity,
      args,
      env: freeze(env),
      data: own(options, 'data'),
      transfer: transfer === undefined ? undefined : freeze([...transfer]),
    });
    configs.add(config);
    return config;
  }

  const closeAll = handles => {
    for (const handle of handles) {
      try {
        native.channel.close(handle);
      } catch {
        // Already closed.
      }
    }
  };

  function create(options) {
    const config = CreateConfig(options);
    ready();
    const down = native.channel.create(config.capacity);
    const up = native.channel.create(config.capacity);
    const done = native.channel.create(1);
    const all = [down.tx, down.rx, up.tx, up.rx, done.tx, done.rx];
    let data = 0;
    let id;
    try {
      if (config.data !== undefined) data = native.channel.stash(config.data, config.transfer);
      const env = [];
      for (const name of Object.keys(config.env)) env.push(name, config.env[name]);
      id = native.isolate.spawn(config.init, JSON.stringify(config.args), JSON.stringify(env), down.rx, up.tx, done.tx, data);
      checked(take());
    } catch (error) {
      closeAll(all);
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
      closeAll([done.rx]);
      const status = statuses[native.isolate.outcome(id)];
      checked(take());
      const reason = native.isolate.failure(id);
      checked(take());
      return freeze(reason === undefined ? { status } : { status, error: reason });
    };
    return freezeMethods({
      id,
      tx: makeSender(down.tx),
      rx: makeReceiver(up.rx),
      terminate() {
        native.isolate.terminate(id);
        checked(take());
      },
      join: () => (joined ??= join()),
    });
  }

  let parent;
  return () => ({
    CreateConfig,
    create,
    // In an isolate made by `create`: `{ tx, rx, data }` to talk to its creator; null in the first isolate.
    get parent() {
      if (parent === undefined) {
        const link = native.isolate.link();
        if (link === undefined) {
          parent = null;
        } else {
          ready();
          const [rx, tx, data] = link;
          native.channel.adopt(rx);
          native.channel.adopt(tx);
          parent = freeze({
            tx: makeSender(tx),
            rx: makeReceiver(rx),
            data: data === 0 ? undefined : native.channel.unstash(data),
          });
        }
      }
      return parent;
    },
  });
};
