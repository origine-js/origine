// `origine:@std/graph/resolve`: how a specifier becomes a module id. A resolver is an ordered list of
// layers; the first layer that returns a result wins and a layer that returns `undefined` passes.
// If no layer answers the import fails `NotFound`.
//
//   ImportResolver.layered().layer(relative()).layer(origine()).layer(nodeModules())
//
// A layer is a host descriptor (`relative()`, `origine()`, `importMap(...)` of
// `origine:@std/graph/resolve/layers`, run natively) or a function
// `({ specifier, referrer, attributes, phase }) => { id, attributes? } | undefined | Promise<...>`
// that runs in the creating realm during the load stage.
import { ERRNO } from 'origine:@std/errno';

const freeze = Object.freeze;
const invalid = message => freeze({ errno: ERRNO.io.InvalidInput, name: 'InvalidInput', message });

const RESOLVER = Symbol.for('origine:@std/graph/resolver');

const isLayer = value =>
  typeof value === 'function' || (value !== null && typeof value === 'object' && typeof value.host === 'string' && value.kind === 'layer');

class Resolver {
  constructor(layers) {
    this[RESOLVER] = true;
    this.layers = freeze(layers);
    freeze(this);
  }

  /// A new resolver with `layer` consulted after the ones already added. The receiver is unchanged.
  layer(layer) {
    if (!isLayer(layer)) throw invalid('ImportResolver.layer: expected a function or a layer descriptor');
    return new Resolver([...this.layers, layer]);
  }
}

export const ImportResolver = freeze({
  /// A resolver with no layers yet; add them with `.layer(...)`.
  layered: () => new Resolver([]),
  is: value => value?.[RESOLVER] === true,
});
