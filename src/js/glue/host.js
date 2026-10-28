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

  return () => ({
    env: makeEnvCap(null),
    threading: freezeMethods({
      get parallelism() {
        return native.threading.parallelism();
      },
    }),
  });
};
