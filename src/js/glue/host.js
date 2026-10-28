// `api.host`: facts about the machine and process the program runs on. Evaluated as an expression
// by src/api/glue.zig: `(native, util) => makeHostCap`. `makeHostCap()` builds the namespace.
// `api.host.env` takes a Set of visible names, or null for all (`makeEnvCap(allow)`).
(native, { freeze, freezeMethods, own }) => {
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

  // Channel ends are frozen objects over an integer `handle`; a handle can be passed to another
  // isolate (as an argument or a message) and turned back into an end with `sender`/`receiver`.
  // `native.channel` exists after the first use of a channel; `api.host` alone never loads the Rust API.
  let channelsReady = false;
  const ready = () => {
    if (!channelsReady) {
      native.threading.attach(native);
      channelsReady = true;
    }
  };
  const handleOf = (value, name) => {
    if (!Number.isInteger(value) || value < 1) throw new TypeError(name + ' must be a positive integer handle');
    return value;
  };
  const makeSender = handle =>
    freezeMethods({
      handle,
      send(value, options) {
        ready();
        return native.channel.send(handle, value, own(options, 'transfer'));
      },
      clone() {
        ready();
        return makeSender(native.channel.clone(handle));
      },
      close() {
        ready();
        native.channel.close(handle);
      },
    });
  const makeReceiver = handle =>
    freezeMethods({
      handle,
      recv() {
        ready();
        return native.channel.recv(handle);
      },
      close() {
        ready();
        native.channel.close(handle);
      },
      // Ends when every sender is closed and the queue is drained.
      async *[Symbol.asyncIterator]() {
        for (;;) {
          let value;
          try {
            ready();
            value = await native.channel.recv(handle);
          } catch (error) {
            if (error !== null && typeof error === 'object' && error.name === 'NotConnected') return;
            throw error;
          }
          yield value;
        }
      },
    });

  return () => ({
    env: makeEnvCap(null),
    threading: freezeMethods({
      get parallelism() {
        return native.threading.parallelism();
      },
      channel(options) {
        const capacity = own(options, 'capacity');
        if (!Number.isInteger(capacity) || capacity < 1 || capacity > 0xffffffff) {
          throw new TypeError('capacity must be an integer from 1 to 2^32 - 1');
        }
        ready();
        const { tx, rx } = native.channel.create(capacity);
        return freeze({ tx: makeSender(tx), rx: makeReceiver(rx) });
      },
      // Taking an end over makes this isolate its owner: it is closed when the isolate goes away.
      sender(handle) {
        ready();
        native.channel.adopt(handleOf(handle, 'handle'));
        return makeSender(handle);
      },
      receiver(handle) {
        ready();
        native.channel.adopt(handleOf(handle, 'handle'));
        return makeReceiver(handle);
      },
    }),
  });
};
