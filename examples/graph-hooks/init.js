// Run: zig-out/bin/origine examples/graph-hooks/init.js   (or: zig build run -- examples/graph-hooks/init.js)
// Hooks answer a resolved id in order: the first verdict that is not ImportHook.next() wins.
// Here: a policy that rejects, origineProvider for origine:@std/* names, a hook that provides a virtual
// module, and fsProvider for files. The handler reports which elements run in JS (`plan`).
//
// Prints (stderr), with the modules' own line in between (values are from a real run):
//   native: false
//   plan: resolver:native:origine resolver:native:relative resolver:js hooks:js hooks:native:origine hooks:js hooks:native:fs ...
//   hello hooks | answer 42 | utf8 bytes 2
//   ./lib/secret.js: ModuleError: ./lib/secret.js: PermissionDenied       (the policy hook; secret.js never runs)
//   origine:@std/debug: ModuleError: origine:@std/debug: PermissionDenied    (not in include: the provider does not serve it)
//   ./lib/nope.js: ModuleError: ./lib/nope.js: NotFound             (no hook serves it; the fs provider finds no file)
import { ModuleSource } from 'origine:@std/graph/module';
import { ImportHandler, ImportHook, ImportError } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { origine, relative } from 'origine:@std/graph/resolve/layers';
import { origineProvider, fsProvider } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  // Authority: a read-only grant of this directory. Files outside it cannot be reached by any hook.
  const src = api.fs.requestSync({ handle: 'plain', root: 'examples/graph-hooks', access: 'r' });
  const graph = api.graph.create();
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered()
      .layer(origine()) // recognises origine: ids
      .layer(relative()) // './x' against the importer
      .layer(({ specifier }) => (specifier === 'virtual:answer' ? { id: specifier } : undefined)),
    hooks: [
      // 1. Policy first. Nothing after this can serve a denied id.
      resolved => (resolved.id === 'lib/secret.js' ? ImportHook.reject(ImportError.PermissionDenied) : ImportHook.next()),
      // 2. origine:@std/* modules. `std` is required; only the names listed are served.
      origineProvider({ std: { include: ['text'] } }),
      // 3. A module made from text the hook holds: nothing is read from disk.
      resolved => (resolved.id === 'virtual:answer' ? ImportHook.source(ModuleSource.text('export const answer = 42;')) : ImportHook.next()),
      // 4. Files under the grant's root. `read` is required: 'copy' or 'mmap'.
      fsProvider({ fs: src, read: 'copy' }),
    ],
  });
  eprintln('native:', handler.native);
  eprintln('plan:', handler.plan.map(p => `${p.stage}:${p.kind}${p.name ? `:${p.name}` : ''}`).join(' '));

  const print = (...a) => eprintln(...a);
  using ctx = await api.context.create({
    import: handler,
    graph,
    preload: [{ source: '(values) => { globalThis.print = values.print; }', values: { print } }],
  });
  await ctx.import('./main.js');

  // Each refused import rejects with a fresh ModuleError; the context keeps working afterwards.
  for (const specifier of ['./lib/secret.js', 'origine:@std/debug', './lib/nope.js']) {
    await ctx.import(specifier).then(
      () => eprintln(specifier, 'imported'),
      e => eprintln(`${specifier}: ${e.name}: ${e.message}`),
    );
  }
}
