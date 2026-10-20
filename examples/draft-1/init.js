import { Dir, IoError, Limit } from 'origine:@std/io';

const text = bytes => String.fromCharCode(...bytes);

export async function main(api) {
  print('args:', api.env.args().join(' '));
  const grant = { root: 'examples/draft-1/work', write: true };
  const sync = api.fs.requestSync(grant);
  const io = api.io.create({});
  const async = await api.fs.requestAsync({ io, ...grant });
  const file = IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'hello.txt', 'w'));
  sync.fileWriteAll(file, Uint8Array.from([104, 105, 10]));
  sync.fileClose(file);
  const again = await async.dirOpenFile(Dir.cwd(), 'hello.txt', 'r');
  print('read back:', JSON.stringify(text(await async.fileReadAll(again, { limit: Limit.unlimited }))));
  await io.close();
  try {
    IoError.check(sync, sync.dirOpenFile(Dir.cwd(), '../escape.txt', 'r'));
  } catch (e) {
    print('escape rejected:', e.name);
  }
  const child = await api.scope.create({
    main: 'app:/main.js',
    importMap: { imports: { dep: 'app:/dep.js' } },
    loader: async id => (id === 'app:/main.js' ? "import { v } from 'dep'; print('child sees', v + preloaded)" : 'export const v = 40;'),
    preload: [{ source: '(values) => { globalThis.preloaded = values.n }', values: { n: 2 } }],
  });
  await child.run();
}
