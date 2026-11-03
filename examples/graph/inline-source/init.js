// Run: zig build run -- examples/graph/inline-source/init.js   (or: zig-out/bin/origine examples/graph/inline-source/init.js)
// Modules need not be files. ModuleSource.text is source in memory (and it needs a name: its id). A hook can answer an
// import with a source (ImportHook.source), with a finished set of values (ImportHook.exports: a synthetic module whose
// namespace is those values, shared with the importer as they are), or refuse it (ImportHook.reject with an ImportError).
//
// Prints (stderr):
//   source map kind: url ; the default is none
//   from source: built in memory ; exported values: answer 42
//   blocked: ModuleError: app:/blocked.js: Error: Unexpected: blocked by policy
import { eprintln } from 'origine:@std/debug';
import { ModuleRecipe, ModuleSource, SourceMap } from 'origine:@std/graph/module';
import { ImportHandler, ImportHook, ImportError } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { importMap, origine } from 'origine:@std/graph/resolve/layers';
import { origineProvider } from 'origine:@std/graph/providers';

const handler = ImportHandler.make({
  resolver: ImportResolver.layered()
    .layer(origine())
    .layer(importMap({ imports: { inline: 'app:/inline.js', config: 'app:/config.js', blocked: 'app:/blocked.js' } })),
  hooks: [
    // Answers the id with a source: the maker turns it into a module of its own.
    resolved => (resolved.id === 'app:/inline.js' ? ImportHook.source(ModuleSource.text("export const text = 'built in memory';")) : ImportHook.next()),
    // Answers with a source that only exports values: the same as ImportHook.exports for data, written as source.
    resolved => (resolved.id === 'app:/config.js' ? ImportHook.source(ModuleSource.text('export const answer = 42;')) : ImportHook.next()),
    // Refuses the import: the importer gets an ImportError with the message.
    resolved => (resolved.id === 'app:/blocked.js' ? ImportHook.reject(ImportError.other('blocked by policy')) : ImportHook.next()),
    origineProvider({ std: { include: ['debug'] } }),
  ],
});

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const root = ModuleRecipe({
    // A text source needs a name: the id the module is known by.
    source: ModuleSource.text(`
      import { eprintln } from 'origine:@std/debug';
      import { text } from 'inline';
      import { answer } from 'config';
      eprintln('from source:', text, '; exported values: answer', answer);
    `),
    name: 'app:/root.js',
    import: handler,
  });
  // A source map is carried with the source for tools; the engine does not fetch or apply it.
  const mapped = ModuleSource.text('export const mapped = 1;', SourceMap.url('app:/root.js.map'));
  eprintln(`source map kind: ${mapped.map.kind} ; the default is ${SourceMap.None.kind}`);

  const graph = api.graph.create();
  using ctx = await api.context.create({ import: handler, graph });
  const reference = graph.declare(root);
  await graph.load(reference);
  await graph.evaluate(reference, ctx);
  await ctx.import('blocked').catch(e => eprintln(`blocked: ${e.name}: ${e.message}`));
  graph.close();
}
