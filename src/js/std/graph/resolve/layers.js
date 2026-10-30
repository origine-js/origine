// `origine:@std/graph/resolve/layers`: resolver layers the host runs natively, so resolving an
// import through them never enters JavaScript. Each call returns an immutable JS descriptor instance; the host
// compiles it when the handler is registered (it holds no authority, see docs/graph-api.md).
import { define } from 'origine:@internal/records';
import { ERRNO } from 'origine:@std/errno';
import { IoError } from 'origine:@std/errors';

const freeze = Object.freeze;
const invalid = message => new IoError(ERRNO.io.InvalidInput, message);
const own = (object, key) => {
  if (object === null || typeof object !== 'object') return undefined;
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  return descriptor !== undefined && 'value' in descriptor ? descriptor.value : undefined;
};

const makeLayer = define('ResolveLayer');
const layer = (host, rest) => makeLayer({ host, kind: 'layer', ...rest });

/// `./x` and `../x` against the importer's id.
export const relative = () => layer('relative');

/// Recognises `origine:` ids. It only canonicalises them; `origineProvider` decides which are served.
export const origine = () => layer('origine');

/// A frozen copy of `record` ({ key: string }), or throws.
const strings = (what, record) => {
  if (record === null || typeof record !== 'object') throw invalid(`importMap: ${what} must be an object`);
  const copy = {};
  for (const key of Object.keys(record)) {
    const value = own(record, key);
    if (key === '' || typeof value !== 'string') throw invalid(`importMap: ${what}[${JSON.stringify(key)}] must be a string`);
    copy[key] = value;
  }
  return freeze(copy);
};

/// Import map data as on the web: `imports` and `scopes`. Read once and copied.
export const importMap = data => {
  if (data === null || typeof data !== 'object') throw invalid('importMap: data must be an object');
  const imports = own(data, 'imports');
  const scopes = own(data, 'scopes');
  const copy = { imports: imports === undefined ? freeze({}) : strings('imports', imports) };
  const scoped = {};
  if (scopes !== undefined) {
    if (scopes === null || typeof scopes !== 'object') throw invalid('importMap: scopes must be an object');
    for (const prefix of Object.keys(scopes)) scoped[prefix] = strings(`scopes[${JSON.stringify(prefix)}]`, own(scopes, prefix));
  }
  copy.scopes = freeze(scoped);
  return layer('importMap', copy);
};
