// `origine:@std/net`: `IpAddr` and `SocketAddr`, plain value types in Rust's vocabulary. They hold no authority
// (parsing and printing an address opens nothing), so they are a module and not a capability. The classes are the
// realm's own (src/js/glue/addr.js): `api.dns` returns and accepts these very instances.
import { provided } from 'origine:@internal/handles';

const classes = provided('net/addr');

export const IpAddr = classes.IpAddr;
export const SocketAddr = classes.SocketAddr;
