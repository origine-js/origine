// `origine:@std/debug`: a debugging hook of the host, the only output a program has without a
// capability. The host hands this module its native through `import.meta.native`, which only the
// embedded `origine:` modules get; it is captured here, never exported.
const { write } = import.meta.native;

/// Writes the values, converted with `String()` and separated by spaces, as one line to the
/// process's standard error.
export function eprintln(...values) {
  write(values.map(String).join(' '));
}
