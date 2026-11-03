// Run: zig build run -- examples/context/security/init.js   (or: zig-out/bin/origine examples/context/security/init.js)
// String-to-code (eval, new Function, the AsyncFunction and GeneratorFunction constructors) is off in every realm by
// default: security.codeGeneration is false, and the call throws EvalError. Turning it on is a per-context decision
// with a cost: a function exported from such a realm lets its importers run code in that realm. Read the CAUTION in
// types/context.d.ts before you turn it on.
//
// Prints (stderr):
//   eval -> EvalError          (the default realm)
//   eval -> 2                  (the realm with codeGeneration: true)
import { ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { origine } from 'origine:@std/graph/resolve/layers';
import { origineProvider } from 'origine:@std/graph/providers';
import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
import { eprintln } from 'origine:@std/debug';

const probe = "import { eprintln } from 'origine:@std/debug'; try { eprintln('eval ->', eval('1 + 1')); } catch (e) { eprintln('eval ->', e.name); }";

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered().layer(origine()),
    hooks: [origineProvider({ std: { include: ['debug'] } })],
  });
  const graph = api.graph.create();
  const recipe = ModuleRecipe({ source: ModuleSource.text(probe), name: 'app:/probe.js', import: handler });

  // The default: string-to-code is refused.
  using safe = await api.context.create({ import: handler, graph });
  await graph.evaluate(graph.declare(recipe), safe).catch(e => eprintln('evaluate failed:', e.name));
  // Turned on for this realm only.
  using open = await api.context.create({ import: handler, graph, security: { codeGeneration: true } });
  await graph.evaluate(graph.declare(recipe), open);
  graph.close();
}
