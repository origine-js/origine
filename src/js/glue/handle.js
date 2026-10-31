// The two bases of what glue hands to init JS. Init JS is trusted, so both are transparent: public
// fields, no private state that a wrapper could not reach. The natives validate every id, owner and
// grant; nothing here is what stops a forged id.
//
//   Handle  a native resource (file, directory). It remembers the issuer that made it, and only a
//           grant requested with `handle: 'hardened'` compares that issuer before calling a native.
//   Data    a frozen record of public fields.
import { seal } from './util.js';

// The issuer a handle was made with (undefined for any other value).
export let issuerOf;

export class Handle {
  #issuer;
  constructor(issuer) {
    this.#issuer = issuer;
  }
  static {
    issuerOf = value => (Object(value) === value && #issuer in value ? value.#issuer : undefined);
    seal(this);
  }
}

export class Data {
  constructor(fields) {
    Object.defineProperties(this, Object.getOwnPropertyDescriptors(fields));
    seal(this);
  }
  static {
    seal(this);
  }
}
