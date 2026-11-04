// `api.tls`: TLS 1.2/1.3 over streams (docs/http-design.md). An ES module factory used by index.js. Every class is
// defined in Rust (rust/crates/origine_api/src/tls.rs, `#[class]`): the values parsed once and reused (`RootPki`,
// `Identity`, `ClientAuth`, `TlsSessions`, `TlsClient`, `TlsServer`) parse and validate in their named constructors,
// so a bad certificate fails with its own error. `TlsClient.connect(stream, { servername, io? })` and
// `TlsServer.accept(stream, { io? })` take a native stream (TCP or TLS, unshaped or idle shaped), which they consume
// and handshake over in Rust without entering JS, or a duck-typed JS stream run on `io`; they resolve a
// `TlsStreamUnshaped`, which `pulling()` / `evented()` turn into `PullTlsStream` / `EventTlsStream` (the members of
// the TCP classes plus `info()`). Nothing here holds state.
import { freeze, hostError, shared } from './util.js';

// Read when the module is evaluated (before guest code): a realm cannot swap them.
const { asyncDispose, asyncIterator } = Symbol;
const READ_CHUNK = 65536;

export default native => {
  // Called when the capability is bound (index.js `late`): the installers exist only then.
  return () => {
    const closing = {
      [asyncDispose]() {
        return this.close();
      },
    };
    const TlsStreamUnshaped = native.tls.TlsStreamUnshaped(hostError, closing);
    const PullTlsStream = native.tls.PullTlsStream(hostError, {
      ...closing,
      /** `for await (const chunk of stream)`: the bytes as `read(65536)` returns them, until the end of the stream. */
      async *[asyncIterator]() {
        for (;;) {
          const chunk = await this.read(READ_CHUNK);
          if (chunk.length === 0) return;
          yield chunk;
        }
      },
    });
    const EventTlsStream = native.tls.EventTlsStream(hostError, closing);
    const infos = [TlsStreamUnshaped, PullTlsStream, EventTlsStream].map(C => C.prototype.info);
    // For `api.http`: what the handshake of a stream settled, or undefined for a stream that is not TLS (the native
    // `info` is brand-checked, so only a genuine TLS stream answers).
    shared.tlsInfo = stream => {
      for (const info of infos) {
        try {
          return info.call(stream);
        } catch {}
      }
      return undefined;
    };
    return freeze({
      RootPki: native.tls.RootPki(hostError),
      Identity: native.tls.Identity(hostError),
      ClientAuth: native.tls.ClientAuth(hostError),
      TlsSessions: native.tls.TlsSessions(hostError),
      TlsClient: native.tls.TlsClient(hostError),
      TlsServer: native.tls.TlsServer(hostError),
      TlsStreamUnshaped,
      PullTlsStream,
      EventTlsStream,
      /** `{ roots: RootPki (required), identity?: Identity, alpn?: string[], sessions?: TlsSessions }`. */
      client(options) {
        return native.tls.client(options);
      },
      /** `{ identities: Identity[] (at least one), clientAuth: ClientAuth (required), alpn?: string[] }`. */
      server(options) {
        return native.tls.server(options);
      },
    });
  };
};
