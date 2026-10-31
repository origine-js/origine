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
import * as h from 'origine:@internal/handles';
import { ERRNO } from 'origine:@std/errno';
import { IoError } from 'origine:@std/errors';

const freeze = Object.freeze;
const invalid = message => new IoError(ERRNO.io.InvalidInput, message);


const isLayer = value => typeof value === 'function' || value instanceof h.ResolveLayer;

class Resolver {
  constructor(layers) {
    this.layers = freeze(layers);
    return new h.ImportResolver({ layers: this.layers, layer: Resolver.prototype.layer });
  }

  /// A new resolver with `layer` consulted after the ones already added. The receiver is unchanged.
  layer(layer) {
    if (!(this instanceof h.ImportResolver)) throw invalid('layer: expected an ImportResolver receiver');
    if (!isLayer(layer)) throw invalid('ImportResolver.layer: expected a function or a layer descriptor');
    return new Resolver([...this.layers, layer]);
  }
}

export const ImportResolver = freeze({
  /// A resolver with no layers yet; add them with `.layer(...)`.
  layered: () => new Resolver([]),
  is: value => value instanceof h.ImportResolver,
});
