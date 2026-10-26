// Evaluates once in the REPL context, retaining helpers privately in host handles.
// Proxy checks are native so neither inspection nor completion invokes Proxy traps.
(isProxy, lookupIdentifier, promiseInfo) => {
  const descriptors = Object.getOwnPropertyDescriptors;
  const descriptor = Object.getOwnPropertyDescriptor;
  const names = Object.getOwnPropertyNames;
  const prototype = Object.getPrototypeOf;
  const ownKeys = Reflect.ownKeys;
  const quote = JSON.stringify;
  const isArray = Array.isArray;
  const same = Object.is;
  const hasOwn = Object.hasOwn;
  const functionSource = Function.prototype.toString;
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
    const breakLength = 80;
    const maxItems = 100;
    let remaining = 100;
    let indentation = 0;
    let deepest = 0;
    function string(value) {
      return quote(value.length > 256 ? value.slice(0, 256) + '…' : value);
    }
    // Spreads a long list of short entries over aligned columns (numbers right-aligned).
    function group(output, numeric, extra) {
      let total = 0;
      let longest = 0;
      const count = output.length - extra;
      for (let i = 0; i < count; i++) {
        total += output[i].length + 2;
        if (longest < output[i].length) longest = output[i].length;
      }
      const cell = longest + 2;
      if (cell * 3 + indentation >= breakLength || (total / cell <= 5 && longest > 6)) return output;
      const bias = Math.sqrt(cell - total / output.length);
      const biased = Math.max(cell - 3 - bias, 1);
      const columns = Math.min(
        Math.round(Math.sqrt(2.5 * biased * count) / biased),
        Math.floor((breakLength - indentation) / cell),
        12,
        15,
      );
      if (columns <= 1) return output;
      const widths = [];
      for (let i = 0; i < columns; i++) {
        let width = 0;
        for (let j = i; j < count; j += columns) if (output[j].length > width) width = output[j].length;
        widths.push(width + 2);
      }
      const rows = [];
      for (let i = 0; i < count; i += columns) {
        const end = Math.min(i + columns, count);
        let row = '';
        let j = i;
        for (; j < end - 1; j++) row += numeric ? (output[j] + ', ').padStart(widths[j - i]) : (output[j] + ', ').padEnd(widths[j - i]);
        row += numeric ? output[j].padStart(widths[j - i] - 2) : output[j];
        rows.push(row);
      }
      for (let i = count; i < output.length; i++) rows.push(output[i]);
      return rows;
    }
    // Joins entries on one line when they fit within the break length, else one per line.
    function reduce(output, open, close, level, grouped, numeric, extra) {
      const entries = output.length;
      if (grouped && entries > 6) output = group(output, numeric, extra);
      if (deepest - level < 3 && entries === output.length) {
        const start = output.length + indentation + open.length + 10;
        let total = output.length + start;
        let fits = total + output.length <= breakLength;
        for (let i = 0; fits && i < output.length; i++) {
          total += output[i].length;
          fits = total <= breakLength;
        }
        if (fits) {
          const joined = output.join(', ');
          if (!joined.includes('\n')) return open + ' ' + joined + ' ' + close;
        }
      }
      const pad = '\n' + ' '.repeat(indentation);
      return open + pad + '  ' + output.join(',' + pad + '  ') + pad + close;
    }
    function nested(value, level) {
      indentation += 2;
      try {
        return format(value, level + 1);
      } finally {
        indentation -= 2;
      }
    }
    function collection(open, close, entries, level, grouped, numeric, extra) {
      if (entries.length === 0) return open + close;
      return reduce(entries, open, close, level, grouped, numeric, extra || 0);
    }
    function functionLabel(value) {
      let source = '';
      try {
        source = call(functionSource, value);
      } catch {}
      const field = descriptor(value, 'name');
      const name = typeof field?.value === 'string' ? field.value.slice(0, 80) : '';
      if (/^class\b/.test(source)) {
        const parent = prototype(value);
        const base =
          parent !== Function.prototype && typeof parent === 'function' && !isProxy(parent) ? descriptor(parent, 'name')?.value : undefined;
        return '[class ' + (name || '(anonymous)') + (typeof base === 'string' && base ? ' extends ' + base.slice(0, 80) : '') + ']';
      }
      const kind = /^async\s*function\s*\*/.test(source)
        ? 'AsyncGeneratorFunction'
        : /^async\b/.test(source)
          ? 'AsyncFunction'
          : /^function\s*\*/.test(source)
            ? 'GeneratorFunction'
            : 'Function';
      return '[' + kind + (name ? ': ' + name : ' (anonymous)') + ']';
    }
    function isWeak(value) {
      for (const [type, name] of [
        [WeakMap, 'WeakMap'],
        [WeakSet, 'WeakSet'],
      ]) {
        try {
          call(type.prototype.has, value, {});
          return name;
        } catch {}
      }
    }
    function boxed(value) {
      for (const [valueOf, name] of [
        [Number.prototype.valueOf, 'Number'],
        [String.prototype.valueOf, 'String'],
        [Boolean.prototype.valueOf, 'Boolean'],
      ]) {
        try {
          return '[' + name + ': ' + format(call(valueOf, value), 0) + ']';
        } catch {}
      }
    }
    function format(value, level) {
      if (typeof value === 'string') return string(value);
      if (typeof value === 'bigint') return toString(value) + 'n';
      if (typeof value === 'number' && same(value, -0)) return '-0';
      if (value === null || (typeof value !== 'object' && typeof value !== 'function')) return toString(value);
      if (isProxy(value)) return '[Proxy]';
      if (ancestors.has(value)) return '[Circular]';
      if (level >= 3 || remaining-- <= 0)
        return typeof value === 'function' ? functionLabel(value) : isArray(value) ? '[Array]' : '[Object]';
      deepest = level;
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
          for (let i = 0; i < Math.min(length, maxItems); i++) entries.push(nested(value[i], level));
          if (length > maxItems) entries.push('… ' + (length - maxItems) + ' more');
          return collection(call(typedName, value) + '(' + length + ') [', ']', entries, level, true, true, length > maxItems ? 1 : 0);
        }
        try {
          const iterator = call(mapEntries, value);
          const entries = [];
          for (let i = 0; i < maxItems + 1; i++) {
            const entry = call(mapNext, iterator);
            if (entry.done) break;
            entries.push(i === maxItems ? '…' : nested(entry.value[0], level) + ' => ' + nested(entry.value[1], level));
          }
          return collection('Map {', '}', entries, level);
        } catch {}
        try {
          const iterator = call(setValues, value);
          const entries = [];
          for (let i = 0; i < maxItems + 1; i++) {
            const entry = call(setNext, iterator);
            if (entry.done) break;
            entries.push(i === maxItems ? '…' : nested(entry.value, level));
          }
          return collection('Set {', '}', entries, level);
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
        const state = promiseInfo(value, false);
        if (state !== undefined) {
          if (state === 'pending') return 'Promise { <pending> }';
          const settled = nested(promiseInfo(value, true), level);
          return 'Promise { ' + (state === 'rejected' ? '<rejected> ' : '') + settled + ' }';
        }
        const weak = isWeak(value);
        if (weak) return weak + ' { <items unknown> }';
        const primitive = boxed(value);
        if (primitive) return primitive;
        const fields = descriptors(value);
        const array = isArray(value);
        const callable = typeof value === 'function';
        let label = '';
        let base = '';
        if (callable) {
          base = functionLabel(value);
        } else if (fields.message && typeof fields.message.value === 'string' && fields.stack) {
          let name = 'Error';
          let object = prototype(value);
          for (let i = 0; object && !isProxy(object) && i < 16; i++, object = prototype(object)) {
            const field = descriptor(object, 'name');
            if (typeof field?.value === 'string') {
              name = field.value;
              break;
            }
          }
          base = name + ': ' + fields.message.value;
        } else if (!array) {
          const proto = prototype(value);
          if (proto === null) label = '[Object: null prototype] ';
          else if (!isProxy(proto)) {
            const ctor = descriptor(proto, 'constructor')?.value;
            const name = typeof ctor === 'function' && !isProxy(ctor) ? descriptor(ctor, 'name')?.value : undefined;
            if (typeof name === 'string' && name !== 'Object') label = name.slice(0, 80) + ' ';
          }
        }
        const isIndex = key => typeof key === 'string' && /^(0|[1-9]\d*)$/.test(key);
        const keys = ownKeys(fields).filter(key => fields[key].enumerable && !(array && (isIndex(key) || key === 'length')));
        const show = key => {
          const field = fields[key];
          const name = typeof key === 'symbol' ? '[' + toString(key) + ']' : /^[A-Za-z_$][\w$]*$/.test(key) ? key : string(key);
          const shown =
            'value' in field
              ? nested(field.value, level)
              : field.get && field.set
                ? '[Getter/Setter]'
                : field.get
                  ? '[Getter]'
                  : '[Setter]';
          return name + ': ' + shown;
        };
        const entries = [];
        let extra = 0;
        let numeric = true;
        if (array) {
          const length = fields.length.value;
          for (let i = 0; i < length && entries.length < maxItems;) {
            if (hasOwn(fields, i)) {
              const field = fields[i];
              if (!('value' in field) || (typeof field.value !== 'number' && typeof field.value !== 'bigint')) numeric = false;
              entries.push('value' in field ? nested(field.value, level) : field.get ? '[Getter]' : '[Setter]');
              i++;
            } else {
              numeric = false;
              let end = i;
              while (end < length && !hasOwn(fields, end)) end++;
              entries.push('<' + (end - i) + ' empty item' + (end - i === 1 ? '' : 's') + '>');
              i = end;
            }
          }
          const counted = entries.length;
          if (counted >= maxItems && length > maxItems) {
            let seen = 0;
            for (const entry of entries) seen += /^<(\d+) empty/.exec(entry)?.[1] ?? 1;
            if (seen < length) {
              entries.push('… ' + (length - seen) + ' more item' + (length - seen === 1 ? '' : 's'));
              extra = 1;
            }
          }
        }
        const named = array ? entries.length : 0;
        for (const key of keys.slice(0, maxItems)) entries.push(show(key));
        if (keys.length > maxItems) entries.push('… ' + (keys.length - maxItems) + ' more');
        if (array) return collection('[', ']', entries, level, named === entries.length, numeric, extra);
        if (base) return entries.length ? reduce(entries, base + ' {', '}', level, false, false, 0) : base;
        return collection(label + '{', '}', entries, level);
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
  // Colors the inspector's output (the line editor's colors come from the Rust side).
  function highlight(text) {
    return text.replace(
      /(["'`])(?:\\.|(?!\1)[^\\])*?\1|\b(?:\d+(?:\.\d+)?n?|true|false|null|undefined|const|let|var|function|return|class|new|throw|await|async)\b|\[[A-Za-z][^\]\n]*\]|<[a-z0-9][^>\n]*>/g,
      token => {
        const color = /^["'`]/.test(token) ? 32 : /^\d/.test(token) ? 33 : token[0] === '[' ? 36 : token[0] === '<' ? 90 : 35;
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
    const text = inspect(value);
    return mode === 'inspectColor' ? highlight(text) : text;
  };
};
