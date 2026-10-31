// Run: zig build run -- examples/typescript/children.ts
// A context loads only what its import handler names, and transforms only what the handler's maker says:
// here TypeScript and JSX by file extension, run natively by the host.
import { ImportHandler, MakeRecipe, Transform } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { importMap, origine } from 'origine:@std/graph/resolve/layers';
import { fromLoader, origineProvider } from 'origine:@std/graph/providers';
import { ts, tsx } from 'origine:@std/transformer/oxc';

export async function main(api: any): Promise<void> {
  const sources: Record<string, string> = {
    'app:/main.ts':
      "import { eprintln } from 'origine:@std/debug'; import { h } from './view.tsx'; const n: number = 2; eprintln(h('b', null, n * 21));",
    // Classic JSX runtime with a custom factory, so no jsx-runtime module is needed.
    'app:/view.tsx':
      "export const h = (tag: string, _p: unknown, ...kids: unknown[]) => `<${tag}>${kids.join('')}</${tag}>`;" +
      '\nexport const unused = <i/>;',
  };
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered()
      .layer(origine())
      .layer(importMap({ imports: { main: 'app:/main.ts', './view.tsx': 'app:/view.tsx' } })),
    hooks: [origineProvider({ std: { include: ['debug'] } }), fromLoader((id: string) => sources[id]!)],
    maker: MakeRecipe.inherit({
      transformer: Transform.byExtension({
        '.ts': ts(),
        '.tsx': tsx({ jsx: 'classic', pragma: 'h' }),
      }),
    }),
  });
  using context = await api.context.create({ graph: api.graph, import: handler });
  await context.import('main');
}
