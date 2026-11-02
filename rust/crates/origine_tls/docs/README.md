# origine_tls

TLS 1.2/1.3 over any byte transport: [rustls](https://github.com/rustls/rustls) on aws-lc-rs, driven
sans-io. It does no I/O itself, needs no V8 and no Zig-built library, so its tests run anywhere with
plain `cargo test -p origine_tls`. Design and decisions: [docs/http-design.md](../../../../docs/http-design.md).
`api.tls` (in `origine_api`) and the DNS resolver (DoT) sit on it.

```
src/lib.rs        exports
src/pki.rs        RootPki, Identity, ClientAuth, TlsSessions  (parsed once, named constructors)
src/config.rs     TlsClient, TlsServer  (immutable configurations; options structs)
src/stream.rs     TlsStream: connect / accept, read, write, shutdown, info
src/transport.rs  Transport: the encrypted bytes underneath (read / write_all with owned buffers)
src/gate.rs       a FIFO async lock for one reader and one writer at a time
src/error.rs      TlsError, CertProblem (one meaning per variant)
src/tests.rs      in-memory pipe transport and the behaviour tests
```

## Behaviour worth knowing

- **Roots and identities are explicit.** `ClientOptions.roots` has no default (`RootPki::bundled()` is
  the Mozilla set compiled in); a client without a `TlsSessions` never resumes; a server hands out its
  first identity when the client's name matches none, and the client then refuses it with
  `NotValidForName`.
- **Truncation is an error.** `read` returns `Ok(0)` only after the peer's `close_notify`. The transport
  ending without it is `TlsError::UnexpectedEof`, also during the handshake.
- **`shutdown` is a half close.** It sends `close_notify` and flushes; reading keeps working; later
  writes fail with `BrokenPipe` (rustls would otherwise accept and never send them). It does not close
  the transport.
- **Full duplex, one at a time.** A `TlsStream` clones cheaply; one task reads while another writes.
  A second concurrent `read` (or `write`) waits its turn. Writers from several tasks interleave at
  record granularity: callers serialize their writes.
- **Cancellation.** Dropping a `read` loses nothing. Dropping a `write` or `shutdown` after it handed a
  record to the transport poisons the stream (`Poisoned`), because the record stream is no longer in step.
- **Backpressure.** rustls keeps at most 16 KiB of undelivered plaintext and 64 KiB of unsent output.
  Encrypted bytes it cannot take yet are kept and fed again after the reader drains plaintext. A read
  that must answer (a key update, an alert) waits for the write turn, which is small and rare.
- **Not covered:** ALPN-based protocol
  selection beyond reporting the result, 0-RTT (off), certificate revocation, client-side SNI override.

Not run under Miri (it reaches aws-lc through FFI); everything else of the crate's logic is plain safe Rust.
