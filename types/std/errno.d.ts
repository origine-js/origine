// `origine:@std/errno`, generated at runtime from `IoErrno` and `HostErrno` in src/api/errno_codes.zig;
// the types come from the same enums (`generated/errno.d.ts`, `just gen-contracts`).
declare module "origine:@std/errno" {
  type Table = import("../generated/errno.d.ts").ErrnoTable;

  /**
   * Frozen `{ io: { Name: code }, host: { Name: code } }`: the two error domains, each a table of every
   * code but `ok`. `io` follows Rust's `std::io::ErrorKind` names, `host` is origine's own runtime
   * concepts. The domain and category of a code are readable from its number (host 1-9, then io in
   * blocks of ten); the names are the contract, not the numbers: look codes up by name. Use them through `IoError` and `HostError` of `origine:@std/io`.
   */
  export const ERRNO: Table;
}
