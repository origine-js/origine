// Run: zig build run -- examples/typescript/children.ts
// A child scope gets transformers only when the init passes them, keyed by file extension.
import { typescript, tsx } from 'origine:@std/transformer/typescript';

export async function main(api: any): Promise<void> {
  const sources: Record<string, string> = {
    'app:/main.ts': "import { h } from './view.tsx'; const n: number = 2; print(h('b', null, n * 21));",
    // Classic JSX runtime with a custom factory, so no jsx-runtime module is needed.
    'app:/view.tsx': "export const h = (tag: string, _p: unknown, ...kids: unknown[]) => `<${tag}>${kids.join('')}</${tag}>`;" +
      '\nexport const unused = <i/>;',
  };
  const child = await api.scope.create({
    main: 'app:/main.ts',
    importMap: { imports: { './view.tsx': 'app:/view.tsx' } },
    loader: (id: string) => sources[id],
    transformers: {
      '.ts': typescript(),
      '.tsx': tsx({ jsx: 'classic', pragma: 'h' }),
    },
  });
  await child.run();
}
