// `api.tls`: TLS 1.2/1.3 over native streams (docs/http-design.md). An ES module factory used by index.js. Every
// class is defined in Rust (rust/crates/origine_api/src/tls.rs, `#[class]`): the values parsed once and reused
// (`RootPki`, `Identity`, `ClientAuth`, `TlsSessions`, `TlsClient`, `TlsServer`) parse and validate in their named
// constructors, so a bad certificate fails with its own error. `TlsClient.connect(stream, { servername })` and
// `TlsServer.accept(stream)` consume a native stream (`TcpStreamUnshaped`, or an idle `PullTcpStream` /
// `EventTcpStream`) and run the handshake in Rust, without entering JS; they resolve a new `TcpStreamUnshaped` whose
// bytes are plaintext, and `info(stream)` tells what the handshake settled. Nothing here holds state.
import { freeze, hostError, shared } from './util.js';

export default native => {
  // Called when the capability is bound (index.js `late`): the installers exist only then.
  return () => {
    // For `api.http`: what the handshake of a stream settled, or undefined for a plain one.
    shared.tlsInfo = stream => {
      try {
        return native.tls.info(stream);
      } catch {
        return undefined;
      }
    };
    return freeze({
      RootPki: native.tls.RootPki(hostError),
      Identity: native.tls.Identity(hostError),
      ClientAuth: native.tls.ClientAuth(hostError),
      TlsSessions: native.tls.TlsSessions(hostError),
      TlsClient: native.tls.TlsClient(hostError),
      TlsServer: native.tls.TlsServer(hostError),
      /**
       * What the handshake of a TLS stream settled: `{ alpn, version, servername, resumed, peer }`; `peer` is the
       * peer's certificates in DER, leaf first (empty when it sent none). `BadHandle` for a stream that is not TLS.
       */
      info(stream) {
        return native.tls.info(stream);
      },
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
