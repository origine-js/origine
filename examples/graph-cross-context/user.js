// The importer, evaluated in context B. lib.js is a hardened link of A's module; counter.js is B's own copy.
import { config, bump, ownIsFrozen, countA } from './lib.js';
import { inc } from './counter.js';

print('B: config copy', JSON.stringify(config), 'frozen:', Object.isFrozen(config));
// bump() is A's function, so it changes A's object; B's copy does not move.
print('B: bump() in A ->', bump(), '| B copy still', config.count, '| A own object frozen:', ownIsFrozen());
try {
  config.count = 99;
} catch (e) {
  print('B: writing the copy throws', e.name);
}
print('B: counter inc() ->', inc(), inc(), '| A counter ->', countA());
