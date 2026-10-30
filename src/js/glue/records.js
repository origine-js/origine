// Realm-private JS classes. Factories are captured by trusted wrappers, never exported
// to guests. Private-field access supplies branding without a JS-to-native call.
function createRecords() {
  const token = {};
  const classes = new Map();
  const objectLike = value => value !== null && (typeof value === 'object' || typeof value === 'function');

  let recordIs;
  let unwrap;
  class Record {
    #tag;
    #state;
    constructor(key, tag, fields, state) {
      if (key !== token) throw new TypeError('Use the resource or descriptor factory');
      this.#tag = tag;
      const descriptors = Object.getOwnPropertyDescriptors(fields);
      Object.defineProperties(this, descriptors);
      // Factories supply prepared fields, not caller option dictionaries. Retain
      // that immutable state for private unwrapping; forged public fields never count.
      this.#state = state === undefined ? Object.freeze(fields) : state;
      Object.freeze(this);
    }
    static {
      recordIs = (value, tag) => objectLike(value) && #tag in value && (tag === undefined || value.#tag === tag);
      unwrap = (value, tag) => (recordIs(value, tag) ? value.#state : undefined);
    }
  }
  Object.freeze(Record.prototype);
  Object.freeze(Record);

  const define = name => {
    if (classes.has(name)) return classes.get(name);
    class Handle extends Record {
      constructor(key, fields, state) {
        super(key, name, fields, state);
      }
    }
    Object.defineProperty(Handle, 'name', { value: name });
    Object.freeze(Handle.prototype);
    Object.freeze(Handle);
    const make = Object.freeze((fields, state) => new Handle(token, fields, state));
    classes.set(name, make);
    return make;
  };
  const make = (name, fields, state) => define(name)(fields, state);
  // Realm-private values one glue factory publishes for the std modules that import this module.
  // The first publication of a name stands; later ones are ignored.
  const published = new Map();
  const publish = (name, value) => {
    if (!published.has(name)) published.set(name, value);
  };
  const internal = name => published.get(name);
  return Object.freeze({ define, make, is: recordIs, unwrap, publish, internal });
}

const records = createRecords();
export const { define, make, is, unwrap, publish, internal } = records;
