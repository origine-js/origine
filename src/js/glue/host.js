// `api.host`: facts about the machine and process the program runs on. Evaluated as an expression
// by src/api/glue.zig: `(native, util) => makeHostCap`. `makeHostCap()` builds the namespace.
// `api.host.env` takes a Set of visible names, or null for all (`makeEnvCap(allow)`).
(native, util) => {
  const { freeze, freezeMethods, own, shared } = util;
  function makeEnvCap(allow) {
    const visible = name => allow === null || allow.has(name);
    return freezeMethods({
      args: () => freeze(native.env.args()),
      get: name => (typeof name === 'string' && visible(name) ? native.env.get(name) : undefined),
      list: () => freeze(native.env.list().filter(visible)),
      narrow(next) {
        const list = own(next, 'allow');
        if (!Array.isArray(list)) throw new TypeError('allow must be an array of names');
        const names = new Set(list.filter(name => typeof name === 'string' && visible(name)));
        return makeEnvCap(names);
      },
    });
  }

  // ---- channels -------------------------------------------------------------------------
  // A channel is a pair of ports. A port is a frozen object over two one-way native channels (`tx` to
  // send, `rx` to receive) and one read mode, `'pull'` (`recv`, `for await`) or `'event'`
  // (`register('message', fn)`), like the handles of `api.net`. Ports are branded natively, which is
  // what lets them travel in a transfer list.
  const PULL = 0;
  const EVENT = 1;
  const DEFAULT_CAPACITY = 16;
  const states = new WeakMap();
  let channelsReady = false;
  // `native.channel` exists after the first use of a channel; `api.host` alone never loads the Rust API.
  const ready = () => {
    if (!channelsReady) {
      native.threading.attach(native);
      native.channel.setPortFactory((tx, rx, mode) => makePort(tx, rx, mode));
      native.channel.identify(native.threading.identity());
      channelsReady = true;
    }
  };
  const errorNamed = (error, name) => error !== null && typeof error === 'object' && error.name === name;
  const failWith = name => {
    const code = util.errors[name];
    throw util.failure(code);
  };
  const live = state => {
    if (state.consumed) failWith('BadHandle');
  };
  // Ports in a transfer list stop working here once the message is queued; one with a read in
  // flight or a started flow cannot be moved.
  const checkTransfer = list => {
    if (list === undefined) return [];
    if (!Array.isArray(list)) throw new TypeError('transfer must be an array');
    const moving = [];
    for (const item of list) {
      const state = states.get(item);
      if (state === undefined) continue;
      live(state);
      if (state.pending > 0 || state.running) failWith('WouldBlock');
      moving.push(state);
    }
    return moving;
  };
  const send = (state, data, options) => {
    live(state);
    ready();
    const transfer = own(options, 'transfer');
    const moving = checkTransfer(transfer);
    const sent = native.channel.send(state.tx, data, transfer);
    for (const moved of moving) moved.consumed = true;
    return sent;
  };
  const closePort = state => {
    live(state);
    ready();
    state.consumed = true;
    let closed = 0;
    for (const handle of [state.tx, state.rx]) {
      try {
        native.channel.close(handle);
        closed++;
      } catch (error) {
        if (!errorNamed(error, 'BadHandle')) throw error;
      }
    }
    if (closed === 0) failWith('BadHandle');
  };

  const pullPort = state => {
    const port = {
      mode: 'pull',
      send: (data, options) => send(state, data, options),
      async recv() {
        live(state);
        ready();
        state.pending++;
        try {
          return await native.channel.recv(state.rx);
        } finally {
          state.pending--;
        }
      },
      // Ends when the peer closed its port and everything it sent was read.
      async *[Symbol.asyncIterator]() {
        for (;;) {
          let event;
          try {
            event = await port.recv();
          } catch (error) {
            if (errorNamed(error, 'NotConnected')) return;
            throw error;
          }
          yield event;
        }
      },
      close: () => closePort(state),
      toEvent() {
        live(state);
        if (state.pending > 0) failWith('WouldBlock');
        state.consumed = true;
        return makePort(state.tx, state.rx, EVENT);
      },
    };
    return port;
  };

  const EVENTS = ['message', 'close', 'error'];
  const fire = (state, name, event) => {
    const failures = [];
    for (const fn of [...state.handlers[name]]) {
      try {
        fn(event);
      } catch (error) {
        failures.push(error);
      }
    }
    for (const error of failures) {
      // A handler that throws goes to the `error` handlers; with none, it is an unhandled rejection.
      if (name !== 'error' && state.handlers.error.length > 0) fire(state, 'error', error);
      else Promise.reject(error);
    }
  };
  const deliver = (state, event) => fire(state, 'message', event);
  const pump = async state => {
    if (state.running) return;
    state.running = true;
    try {
      while (!state.consumed && !state.paused && state.handlers.message.length > 0) {
        if (state.held.length > 0) {
          deliver(state, state.held.shift());
          continue;
        }
        let event;
        try {
          event = await native.channel.recv(state.rx);
        } catch (error) {
          if (state.consumed) return;
          if (errorNamed(error, 'NotConnected')) {
            state.consumed = true;
            fire(state, 'close', undefined);
          } else {
            fire(state, 'error', error);
          }
          return;
        }
        if (state.consumed) return;
        if (state.paused || state.handlers.message.length === 0) state.held.push(event);
        else deliver(state, event);
      }
    } finally {
      state.running = false;
    }
  };
  const eventPort = state => {
    state.handlers = { message: [], close: [], error: [] };
    state.held = [];
    state.paused = false;
    return {
      mode: 'event',
      send: (data, options) => send(state, data, options),
      register(name, fn) {
        live(state);
        if (!EVENTS.includes(name)) throw new TypeError("event must be 'message', 'close' or 'error'");
        if (typeof fn !== 'function') throw new TypeError('handler must be a function');
        ready();
        state.handlers[name].push(fn);
        if (name === 'message') pump(state);
        return freeze({
          unregister() {
            const at = state.handlers[name].indexOf(fn);
            if (at < 0) return false;
            state.handlers[name].splice(at, 1);
            return true;
          },
        });
      },
      pause() {
        live(state);
        state.paused = true;
      },
      resume() {
        live(state);
        state.paused = false;
        if (state.handlers.message.length > 0) pump(state);
      },
      get paused() {
        return state.paused;
      },
      close() {
        closePort(state);
        fire(state, 'close', undefined);
      },
      toPull() {
        live(state);
        if (state.running) failWith('Unsupported');
        state.consumed = true;
        return makePort(state.tx, state.rx, PULL);
      },
    };
  };

  function makePort(tx, rx, mode) {
    ready();
    const state = { tx, rx, consumed: false, pending: 0, running: false };
    const port = mode === EVENT ? eventPort(state) : pullPort(state);
    native.channel.brand(port, tx, rx, mode);
    freezeMethods(port);
    states.set(port, state);
    return port;
  }

  // `new Channel({ mode })`: a pair of connected ports, `[port, remotePort]`. Whatever one sends the
  // other receives, in order. `capacity` (default 16) is how many messages wait in each direction before
  // `send` waits.
  function Channel(options) {
    if (new.target === undefined) throw new TypeError('Channel must be called with new');
    const mode = own(options, 'mode');
    if (mode !== 'pull' && mode !== 'event') throw new TypeError("mode must be 'pull' or 'event'");
    const capacity = own(options, 'capacity') ?? DEFAULT_CAPACITY;
    if (!Number.isInteger(capacity) || capacity < 1 || capacity > 0xffffffff) {
      throw new TypeError('capacity must be an integer from 1 to 2^32 - 1');
    }
    ready();
    const a = native.channel.create(capacity);
    const b = native.channel.create(capacity);
    const code = mode === 'event' ? EVENT : PULL;
    return freeze([makePort(a.tx, b.rx, code), makePort(b.tx, a.rx, code)]);
  }
  freeze(Channel);

  // `api.isolate` builds its internal channels from the same pieces.
  shared.channels = { ready };

  return () => ({
    env: makeEnvCap(null),
    threading: freezeMethods({
      get parallelism() {
        return native.threading.parallelism();
      },
      Channel,
    }),
  });
};
