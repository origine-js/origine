// The child isolate's init module: main(api, data) where data is what the parent passed.
import { eprintln } from 'origine:@std/debug';

export async function main(api, { port }) {
  eprintln(`worker: args ${api.host.env.args().join(' ')} and MODE=${api.host.env.get('MODE')}`);
  for await (const event of port) await port.send(event.data.n * 2);
}
