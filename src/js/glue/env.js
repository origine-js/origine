// `api.env`: the env capability factory. Evaluated as an expression by src/api/glue.zig:
// `(native, util) => makeEnvCap`. `makeEnvCap(allow)` takes a Set of visible names, or null for all.
(native, { freeze, own }) => {
  function makeEnvCap(allow) {
    const visible = name => allow === null || allow.has(name);
    return freeze({
      args: () => freeze(native.env.args()),
      get: name => (typeof name === 'string' && visible(name)) ? native.env.get(name) : undefined,
      list: () => freeze(native.env.list().filter(visible)),
      narrow(next) {
        const list = own(next, 'allow');
        if (!Array.isArray(list)) throw new TypeError('allow must be an array of names');
        const names = new Set(list.filter(name => typeof name === 'string' && visible(name)));
        return makeEnvCap(names);
      },
    });
  }

  return makeEnvCap;
}
