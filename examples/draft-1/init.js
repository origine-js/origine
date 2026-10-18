import { Dir, IoError, Limit } from '@engine/std/io';

const text = bytes => String.fromCharCode(...bytes);

export async function main(api) {
  print('args:', api.env.args().join(' '));
  const fs = await api.fs.request({ root: 'examples/draft-1/work', write: true, mode: { async: true, sync: true } });
  const file = IoError.check(fs, fs.sync.dirOpenFile(Dir.cwd(), 'hello.txt', 'w'));
  fs.sync.fileWriteAll(file, Uint8Array.from([104, 105, 10]));
  fs.sync.fileClose(file);
  const again = await fs.async.dirOpenFile(Dir.cwd(), 'hello.txt', {});
  print('read back:', JSON.stringify(text(await fs.async.fileReadAll(again, { limit: Limit.unlimited }))));
  try {
    IoError.check(fs, fs.sync.dirOpenFile(Dir.cwd(), '../escape.txt', {}));
  } catch (e) {
    print('escape rejected:', e.name);
  }
  const child = await api.scope.create({
    main: 'app:/main.js',
    importMap: { imports: { dep: 'app:/dep.js' } },
    loader: async id => id === 'app:/main.js'
      ? "import { v } from 'dep'; print('child sees', v + preloaded)"
      : 'export const v = 40;',
    preload: [{ source: '(values) => { globalThis.preloaded = values.n }', values: { n: 2 } }],
  });
  await child.run();
}
