// `api.net`: loopback TCP on an io runtime. Evaluated as an expression by src/api/glue.zig:
// `(native, util) => makeNetCap`. `makeNetCap()` returns the frozen `{ listen, connect }`.
// Handles are instances of the `Handle` classes below: the native id lives in a private field
// the guest cannot read or swap, only this file can construct them (`token`), and methods
// brand-check their receiver. Every native call still re-validates owner and runtime in Rust.
(native, { freeze, own, failure, ioHandles, closedIo, errors: { BadHandle } }) => {
  const token = {};
  let idOf;
  const MAX_READ = 1 << 28;

  class Handle {
    #id;
    #io;
    #closed = false;
    constructor(made, id, io) {
      if (made !== token || new.target === Handle) throw new TypeError('handles are created by api.net');
      this.#id = id;
      this.#io = io;
    }
    static {
      idOf = handle => {
        if (handle === null || typeof handle !== 'object' || !(#id in handle)) throw new TypeError('not a handle');
        return handle.#id;
      };
    }
    /** The io runtime this handle belongs to. */
    get io() {
      return this.#io;
    }
    /** True after `close()` or once the io runtime is closed. */
    get closed() {
      return this.#closed || closedIo.has(this.#io);
    }
    /** Releases the handle; pending reads finish with end of stream. Idempotent. */
    close() {
      try {
        if (!this.closed) {
          this.#closed = true;
          native.net.close(this.#id);
        }
        return Promise.resolve();
      } catch (e) {
        return Promise.reject(e);
      }
    }
  }
  if (typeof Symbol.asyncDispose === 'symbol') {
    Object.defineProperty(Handle.prototype, Symbol.asyncDispose, {
      value: function () {
        return this.close();
      },
      writable: true,
      configurable: true,
    });
  }

  const live = handle => {
    const id = idOf(handle);
    if (handle.closed) throw failure(BadHandle);
    return id;
  };

  class Server extends Handle {
    #port;
    constructor(made, id, io, port) {
      super(made, id, io);
      this.#port = port;
    }
    /** The port listened on (the real one when `port: 0` was asked). */
    get port() {
      return this.#port;
    }
    /** Resolves the next connection as a `Socket`. */
    accept() {
      try {
        const io = this.io;
        return native.net.accept(live(this)).then(r => new Socket(token, r.id, io, r.port));
      } catch (e) {
        return Promise.reject(e);
      }
    }
  }

  class Socket extends Handle {
    #remotePort;
    constructor(made, id, io, remotePort) {
      super(made, id, io);
      this.#remotePort = remotePort;
    }
    get remotePort() {
      return this.#remotePort;
    }
    /** Reads once: a `Uint8Array` of 1 to `length` bytes, empty at end of stream. */
    read(length) {
      try {
        if (!Number.isSafeInteger(length) || length < 1 || length > MAX_READ) throw new TypeError('length must be an integer in 1..2**28');
        return native.net.read(live(this), length);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /**
     * Reads once into `buffer` (an ArrayBuffer or view): resolves the byte count, 0 at end of
     * stream. The buffer is not detached, so one buffer can serve every read.
     */
    readInto(buffer) {
      try {
        if (!(buffer instanceof ArrayBuffer) && !ArrayBuffer.isView(buffer)) throw new TypeError('buffer must be an ArrayBuffer or a view');
        return native.net.readInto(live(this), buffer);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /** Writes all of `data` (an ArrayBuffer or a view; it is copied). Resolves the byte count. */
    write(data) {
      try {
        if (!(data instanceof ArrayBuffer) && !ArrayBuffer.isView(data)) throw new TypeError('data must be an ArrayBuffer or a view');
        return native.net.write(live(this), data);
      } catch (e) {
        return Promise.reject(e);
      }
    }
  }

  freeze(Handle);
  freeze(Handle.prototype);
  freeze(Server);
  freeze(Server.prototype);
  freeze(Socket);
  freeze(Socket.prototype);

  // A live `io` handle made by this scope's `api.io`; the natives validate the id again.
  const ioId = io => {
    if (io === null || typeof io !== 'object' || !ioHandles.has(io) || closedIo.has(io)) throw failure(BadHandle);
    return io.id;
  };
  const address = options => {
    if (options !== undefined && (options === null || typeof options !== 'object')) throw new TypeError('options must be an object');
    const host = own(options, 'host') ?? '127.0.0.1';
    const port = own(options, 'port') ?? 0;
    if (typeof host !== 'string') throw new TypeError('host must be a string');
    if (!Number.isInteger(port) || port < 0 || port > 65535) throw new TypeError('port must be an integer in 0..65535');
    return [host, port];
  };

  return () =>
    freeze({
      Handle,
      Server,
      Socket,
      /** Binds and listens (loopback only). Synchronous; throws `{ errno, name }`. */
      listen(io, options) {
        const [host, port] = address(options);
        const made = native.net.listen(ioId(io), host, port);
        return new Server(token, made.id, io, made.port);
      },
      /** Connects to a loopback listener. */
      connect(io, options) {
        try {
          const [host, port] = address(options);
          return native.net.connect(ioId(io), host, port).then(r => new Socket(token, r.id, io, r.port));
        } catch (e) {
          return Promise.reject(e);
        }
      },
    });
};
