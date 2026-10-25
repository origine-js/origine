// Evaluates once in the REPL context, retaining helpers privately in host handles.
// Proxy checks are native so neither inspection nor completion invokes Proxy traps.
(isProxy, lookupIdentifier) => {
  const descriptors = Object.getOwnPropertyDescriptors;
  const descriptor = Object.getOwnPropertyDescriptor;
  const names = Object.getOwnPropertyNames;
  const prototype = Object.getPrototypeOf;
  const ownKeys = Reflect.ownKeys;
  const quote = JSON.stringify;
  const isArray = Array.isArray;
  const same = Object.is;
  const toString = String;
  const SetType = Set;
  const lexical = new SetType();
  const call = Function.prototype.call.bind(Function.prototype.call);
  const mapEntries = Map.prototype.entries;
  const setValues = Set.prototype.values;
  const mapNext = prototype(new Map().entries()).next;
  const setNext = prototype(new Set().values()).next;
  const dateTime = Date.prototype.getTime;
  const dateIso = Date.prototype.toISOString;
  const regexpSource = descriptor(RegExp.prototype, 'source').get;
  const regexpFlags = ['hasIndices', 'global', 'ignoreCase', 'multiline', 'dotAll', 'unicode', 'unicodeSets', 'sticky'].map(
    name => descriptor(RegExp.prototype, name)?.get,
  );
  const typedPrototype = prototype(Uint8Array.prototype);
  const typedLength = descriptor(typedPrototype, 'length').get;
  const typedName = descriptor(typedPrototype, Symbol.toStringTag).get;
  const arrayBufferLength = descriptor(ArrayBuffer.prototype, 'byteLength').get;
  const keywords = [
    'async',
    'await',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'debugger',
    'default',
    'delete',
    'do',
    'else',
    'export',
    'extends',
    'false',
    'finally',
    'for',
    'function',
    'if',
    'import',
    'in',
    'instanceof',
    'let',
    'new',
    'null',
    'return',
    'static',
    'super',
    'switch',
    'this',
    'throw',
    'true',
    'try',
    'typeof',
    'undefined',
    'var',
    'void',
    'while',
    'yield',
  ];
  const root = globalThis;

  function inspect(value) {
    const ancestors = new SetType();
    let remaining = 100;
    function string(value) {
      return quote(value.length > 256 ? value.slice(0, 256) + '…' : value);
    }
    function collection(open, close, entries, depth) {
      if (entries.length === 0) return open + close;
      const compact = open + ' ' + entries.join(', ') + ' ' + close;
      if (!compact.includes('\n') && compact.length + depth * 2 <= 80) return compact;
      const indent = '  '.repeat(depth + 1);
      return open + '\n' + indent + entries.join(',\n' + indent) + '\n' + '  '.repeat(depth) + close;
    }
    function format(value, depth) {
      if (typeof value === 'string') return string(value);
      if (typeof value === 'bigint') return toString(value) + 'n';
      if (typeof value === 'number' && same(value, -0)) return '-0';
      if (value === null || (typeof value !== 'object' && typeof value !== 'function')) return toString(value);
      if (isProxy(value)) return '[Proxy]';
      if (ancestors.has(value)) return '[Circular]';
      if (depth >= 3 || remaining-- <= 0) return isArray(value) ? '[Array]' : '[Object]';
      ancestors.add(value);
      try {
        // Intrinsic methods perform brand checks and do not call user getters,
        // custom inspect hooks, Symbol.iterator, or Symbol.toStringTag accessors.
        if (ArrayBuffer.isView(value)) {
          let length;
          try {
            length = call(typedLength, value);
          } catch {
            return 'DataView {}';
          }
          const entries = [];
          for (let i = 0; i < Math.min(length, 20); i++) entries.push(format(value[i], depth + 1));
          if (length > 20) entries.push('… ' + (length - 20) + ' more');
          return collection(call(typedName, value) + '(' + length + ') [', ']', entries, depth);
        }
        try {
          const iterator = call(mapEntries, value);
          const entries = [];
          for (let i = 0; i < 21; i++) {
            const entry = call(mapNext, iterator);
            if (entry.done) break;
            entries.push(i === 20 ? '…' : format(entry.value[0], depth + 1) + ' => ' + format(entry.value[1], depth + 1));
          }
          return collection('Map {', '}', entries, depth);
        } catch {}
        try {
          const iterator = call(setValues, value);
          const entries = [];
          for (let i = 0; i < 21; i++) {
            const entry = call(setNext, iterator);
            if (entry.done) break;
            entries.push(i === 20 ? '…' : format(entry.value, depth + 1));
          }
          return collection('Set {', '}', entries, depth);
        } catch {}
        try {
          return Number.isNaN(call(dateTime, value)) ? 'Invalid Date' : call(dateIso, value);
        } catch {}
        try {
          const source = call(regexpSource, value);
          return '/' + source + '/' + regexpFlags.map((get, i) => (get && call(get, value) ? 'dgimsuvy'[i] : '')).join('');
        } catch {}
        try {
          return 'ArrayBuffer { byteLength: ' + call(arrayBufferLength, value) + ' }';
        } catch {}
        if (typeof value === 'function') {
          const name = descriptor(value, 'name');
          return '[Function' + (typeof name?.value === 'string' && name.value ? ': ' + name.value.slice(0, 80) : '') + ']';
        }
        const fields = descriptors(value);
        if (fields.message && typeof fields.message.value === 'string' && fields.stack) {
          let name = 'Error';
          let object = prototype(value);
          for (let i = 0; object && !isProxy(object) && i < 16; i++, object = prototype(object)) {
            const field = descriptor(object, 'name');
            if (typeof field?.value === 'string') {
              name = field.value;
              break;
            }
          }
          return name + ': ' + fields.message.value;
        }
        const array = isArray(value);
        const keys = ownKeys(fields).filter(key => fields[key].enumerable);
        const entries = [];
        for (const key of keys.slice(0, 20)) {
          const field = fields[key];
          const name = typeof key === 'symbol' ? '[' + toString(key) + ']' : /^[A-Za-z_$][\w$]*$/.test(key) ? key : string(key);
          const shown =
            'value' in field
              ? format(field.value, depth + 1)
              : field.get && field.set
                ? '[Getter/Setter]'
                : field.get
                  ? '[Getter]'
                  : '[Setter]';
          entries.push(array && typeof key === 'string' && /^(0|[1-9]\d*)$/.test(key) ? shown : name + ': ' + shown);
        }
        if (keys.length > 20) entries.push('… ' + (keys.length - 20) + ' more');
        if (array && fields.length?.value > keys.length) entries.push('<empty slots>');
        if (array) return collection('[', ']', entries, depth);
        let label = '';
        const proto = prototype(value);
        if (proto !== null && !isProxy(proto)) {
          const ctor = descriptor(proto, 'constructor')?.value;
          const name = typeof ctor === 'function' && !isProxy(ctor) ? descriptor(ctor, 'name')?.value : undefined;
          if (typeof name === 'string' && name !== 'Object') label = name.slice(0, 80) + ' ';
        }
        return collection(label + '{', '}', entries, depth);
      } catch {
        return '[Uninspectable]';
      } finally {
        ancestors.delete(value);
      }
    }
    return format(value, 0);
  }

  // Only global properties and simple dotted paths. Resolve data descriptors,
  // skipping accessors, rather than evaluating the user's completion expression.
  function complete(prefix) {
    if (/^\.[a-z]*$/.test(prefix))
      return (
        ['.again', '.break', '.clear', '.complete', '.exit', '.help', '.history'].filter(name => name.startsWith(prefix)).join('\n') ||
        '(no completions)'
      );
    if (prefix !== '' && !/^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*\.?$/.test(prefix)) return 'Use a global name or dotted property prefix.';
    const parts = prefix.split('.');
    const partial = parts.pop();
    let target = root;
    function find(object, key) {
      for (let n = 0; object != null && n < 32; n++, object = prototype(object)) {
        if (isProxy(object)) return undefined;
        const field = descriptor(object, key);
        if (field) return 'value' in field ? field.value : undefined;
      }
    }
    try {
      for (const [i, part] of parts.entries()) {
        target = i === 0 && part === 'this' ? root : i === 0 && lexical.has(part) ? lookupIdentifier(part) : find(target, part);
        if (typeof target === 'string' || typeof target === 'number' || typeof target === 'boolean' || typeof target === 'bigint')
          target = Object(target);
        if (target === null || (typeof target !== 'object' && typeof target !== 'function')) return '(no completions)';
      }
      const found = new SetType(parts.length ? [] : keywords.filter(name => name.startsWith(partial)));
      if (!parts.length) for (const name of lexical) if (name.startsWith(partial)) found.add(name);
      for (let object = target, n = 0; object != null && n < 32; object = prototype(object), n++) {
        if (isProxy(object)) break;
        // Typed-array indices are never identifier completions. Avoid allocating
        // one property name per element of a potentially very large buffer.
        for (const name of names(ArrayBuffer.isView(object) ? prototype(object) : object)) {
          if (/^[A-Za-z_$][\w$]*$/.test(name) && name.startsWith(partial)) found.add(name);
        }
      }
      const matches = [...found].sort();
      const base = parts.length ? parts.join('.') + '.' : '';
      return matches.length
        ? matches
            .slice(0, 100)
            .map(name => base + name)
            .join('\n') + (matches.length > 100 ? '\n…' : '')
        : '(no completions)';
    } catch {
      return '(no completions)';
    }
  }
  function track(source) {
    // Validate identifier candidates through the private V8 adapter. This also
    // finds destructured and comma-separated bindings without rewriting their
    // const/let semantics or enabling guest eval. Global properties already
    // have descriptor-based completion and must not be read through this path.
    const declared = new SetType([...source.matchAll(/\b(?:let|const|class)\s+([A-Za-z_$][\w$]*)/g)].map(match => match[1]));
    const candidates = new SetType(source.match(/[A-Za-z_$][\w$]*/g) || []);
    let remaining = 1024;
    for (const name of candidates) {
      if (remaining-- <= 0) break;
      if (keywords.includes(name) || lexical.has(name)) continue;
      let object = root;
      let skip = false;
      for (let i = 0; object && !isProxy(object) && i < 32; i++, object = prototype(object)) {
        const field = descriptor(object, name);
        if (field) {
          skip = !('value' in field) || !declared.has(name);
          break;
        }
      }
      if (skip) continue;
      if (lookupIdentifier(name, true)) lexical.add(name);
    }
  }
  function highlight(text) {
    return text.replace(
      /(["'`])(?:\\.|(?!\1)[^\\])*?\1|\b(?:\d+(?:\.\d+)?n?|true|false|null|undefined|const|let|var|function|return|class|new|throw|await|async)\b|\[[A-Za-z][^\]\n]*\]/g,
      token => {
        const color = /^["'`]/.test(token) ? 32 : /^\d/.test(token) ? 33 : token[0] === '[' ? 36 : 35;
        return '\x1b[' + color + 'm' + token + '\x1b[0m';
      },
    );
  }
  return (mode, value) => {
    if (mode === 'complete') return complete(value);
    if (mode === 'track') {
      track(value);
      return undefined;
    }
    if (mode === 'result' || mode === 'error') {
      root[mode === 'result' ? '_' : '_error'] = value;
      return undefined;
    }
    if (mode === 'line' || mode === 'highlight') {
      const text = value.replace(/[\x00-\x1f\x7f]/g, ch => (ch === '\n' ? '↵' : ' ')); // eslint-disable-line no-control-regex -- prevent terminal control injection
      return mode === 'highlight' ? highlight(text) : text;
    }
    const text = inspect(value);
    return mode === 'inspectColor' ? highlight(text) : text;
  };
};
