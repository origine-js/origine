// Run: zig build run -- examples/host/threading/init.js   (or: zig-out/bin/origine examples/host/threading/init.js)
// Channels: two connected ports, in this isolate or in another (see examples/isolate). A port is made in one of two
// read modes, chosen explicitly and visible in its class: 'pull' (await recv()) or 'event' (register handlers).
// Values are structured clones; an ArrayBuffer or a port that must move is listed in `transfer`, and it is detached
// or closed on the sending side.
//
// Prints (stderr):
//   pull: hello from [port], Map entry k=1, identity 0
//   transfer: received 3 bytes, the sent buffer is detached: true
//   a port moved inside a message: reply "pong"
//   event: 3 messages in order: 1,2,3 ; then the close event
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const { Channel } = api.host.threading;
  eprintln(`parallelism: ${api.host.threading.parallelism >= 1}`);

  // Pull mode: every message is a promise. A MessageEvent is { identity, data, transfer }.
  const [port, remote] = new Channel({ mode: 'pull' });
  await port.send({ hello: 'from [port]', map: new Map([['k', 1]]) });
  const message = await remote.recv();
  eprintln(`pull: ${message.data.hello}, Map entry k=${message.data.map.get('k')}, identity ${message.identity}`);

  // A buffer listed in transfer moves: it is detached here and the receiver gets it in `transfer`.
  const bytes = Uint8Array.from([1, 2, 3]).buffer;
  await port.send(bytes, { transfer: [bytes] });
  const moved = await remote.recv();
  eprintln(`transfer: received ${moved.transfer[0].byteLength} bytes, the sent buffer is detached: ${bytes.byteLength === 0}`);

  // A port moved inside a message: the receiver gets a working port of the same mode, talking to the other end.
  const [reply, replyRemote] = new Channel({ mode: 'pull' });
  await port.send({ reply: replyRemote }, { transfer: [replyRemote] });
  const withPort = await remote.recv();
  await withPort.data.reply.send('pong');
  eprintln(`a port moved inside a message: reply "${(await reply.recv()).data}"`);
  port.close();
  remote.close();

  // Event mode: handlers run from the host loop, in order. The 'close' event follows the last message.
  const [events, eventsRemote] = new Channel({ mode: 'event' });
  const received = [];
  eventsRemote.register('message', e => received.push(e.data));
  const closed = new Promise(resolve => eventsRemote.register('close', resolve));
  for (const n of [1, 2, 3]) await events.send(n);
  events.close();                        // an event port with a message handler keeps the program alive until closed
  await closed;
  eprintln(`event: ${received.length} messages in order: ${received.join(',')} ; then the close event`);
}
