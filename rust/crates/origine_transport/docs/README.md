# origine_transport

The one trait the protocol crates read and write bytes through, with no dependencies:
`Transport::read(buf) -> (io::Result<usize>, buf)` and `Transport::write_all(buf) -> (io::Result<()>, buf)`.
Buffers are owned and handed back (the way `origine_io` ops take them), futures are `!Send`, and `0` from
`read` is the end of the stream. `Rc<T>` is a `Transport` when `T` is.

Implementations: an `api.net` socket (in `origine_api`), `origine_tls::TlsStream` (so a
protocol runs over TLS), and, with the `testing` feature, `pipe::pipe()`: two in-memory ends where
dropping one closes it. The protocol crates' tests use it as a dev-dependency.
