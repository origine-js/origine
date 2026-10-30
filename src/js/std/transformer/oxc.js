import { define } from 'origine:@internal/records';
// `origine:@std/transformer/oxc`: host transformers for the module graph (`ModuleSource#withTransformer`,
// `Transform.byExtension`, the maker of an `ImportHandler`). `ts(options)` returns an immutable JS descriptor instance
// `{ host: 'oxc', kind: 'transformer', transform, options }` that the host runs natively on module
// source when a context loads it, so a handler built from these never enters JavaScript. Pure data:
// it holds no authority and can be built in the init snapshot.
//
//   const transformer = Transform.byExtension({ '.ts': ts(), '.tsx': tsx() });
//
// Options (all optional): jsx: 'automatic' | 'classic', importSource, pragma, pragmaFrag,
// development, verbatimImports, inlineSourceMap. Anything of the wrong type throws a TypeError.
const freeze = Object.freeze;

const own = (object, key) => {
  if (object === null || typeof object !== 'object') return undefined;
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  return descriptor !== undefined && 'value' in descriptor ? descriptor.value : undefined;
};

const STRINGS = ['importSource', 'pragma', 'pragmaFrag'];
const FLAGS = ['development', 'verbatimImports', 'inlineSourceMap'];

/// The options as plain data, validated.
const checked = options => {
  if (options === undefined) return freeze({});
  if (options === null || typeof options !== 'object') throw new TypeError('options must be an object');
  const out = {};
  const jsx = own(options, 'jsx');
  if (jsx !== undefined) {
    if (jsx !== 'automatic' && jsx !== 'classic') throw new TypeError("jsx must be 'automatic' or 'classic'");
    out.jsx = jsx;
  }
  for (const name of STRINGS) {
    const value = own(options, name);
    if (value === undefined) continue;
    if (typeof value !== 'string') throw new TypeError('importSource, pragma and pragmaFrag must be strings');
    out[name] = value;
  }
  for (const name of FLAGS) {
    const value = own(options, name);
    if (value === undefined) continue;
    if (typeof value !== 'boolean') throw new TypeError('development, verbatimImports and inlineSourceMap must be booleans');
    out[name] = value;
  }
  return freeze(out);
};

const makeTransformer = define('Transformer');
const make = (transform, options) => makeTransformer({ host: 'oxc', kind: 'transformer', transform, options: checked(options) });

export const ts = options => make('ts', options);
export const tsx = options => make('tsx', options);
export const jsx = options => make('jsx', options);
