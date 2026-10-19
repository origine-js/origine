// `origine:@std/transformer/typescript`: host transformers for `api.scope.create({ transformers })`.
// `typescript(options)` returns a native function `(source, id) => string` (it throws a
// SyntaxError with `file:line:col` diagnostics) that the host also recognizes, so a child
// scope runs it without calling back into JavaScript. `tsx` and `jsx` are the same factory
// under names that read better next to their extensions:
//
//   const ts = typescript();
//   await api.scope.create({ main, loader, transformers: { '.ts': ts, '.mts': ts } });
//
// Options (all optional): jsx: 'automatic' | 'classic', importSource, pragma, pragmaFrag,
// development, verbatimImports, inlineSourceMap.
const native = import.meta.native;
delete import.meta.native;

export const typescript = options => native.make(options);
export const tsx = typescript;
export const jsx = typescript;
