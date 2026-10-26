// `origine:@std/text`: the hardened context has no `TextEncoder`/`TextDecoder`.
declare module "origine:@std/text" {
  /** Options of {@link decodeUtf8}, as `TextDecoder`'s. */
  export interface DecodeOptions {
    /** Throw a `TypeError` for invalid input instead of substituting U+FFFD. Default `false`. */
    readonly fatal?: boolean;
    /** Keep a leading byte order mark instead of dropping it. Default `false`. */
    readonly ignoreBOM?: boolean;
  }

  /** Encodes a string as UTF-8 into a new `Uint8Array`. Lone surrogates become U+FFFD, like `TextEncoder`. */
  export function encodeUtf8(text: string): Uint8Array<ArrayBuffer>;

  /**
   * Decodes UTF-8 like `new TextDecoder('utf-8', { fatal, ignoreBOM }).decode(bytes)`: each maximal
   * invalid subpart (overlong forms, surrogates, above U+10FFFF, truncation, stray bytes) becomes one
   * U+FFFD, and a leading BOM is dropped unless `ignoreBOM`. With `fatal`, invalid input throws a `TypeError`.
   */
  export function decodeUtf8(bytes: Uint8Array, options?: DecodeOptions): string;

  /**
   * The strict form: the string, or **`null`** when `bytes` is not valid UTF-8. Never throws, never
   * substitutes U+FFFD and keeps a leading BOM. Callers choose their own error for `null`
   * (`fs.read_to_string` fails with `InvalidData`).
   */
  export function tryDecodeUtf8(bytes: Uint8Array): string | null;

  /** The plain JavaScript implementations (also the fallback when the natives are absent): the reference for tests and benchmarks. */
  export const utf8Js: {
    readonly encode: (text: string) => Uint8Array<ArrayBuffer>;
    readonly decode: (bytes: Uint8Array, options?: DecodeOptions) => string;
    readonly tryDecode: (bytes: Uint8Array) => string | null;
  };
}
