// The importer, evaluated in context B. lib.js is A's module itself (a link); counter.js is B's own copy.
import { config, bump, ownIsFrozen, countA } from './lib.js';
import { inc } from './counter.js';

print('B: config', JSON.stringify(config), 'frozen:', Object.isFrozen(config));
// bump() is A's function and config is A's object: B sees the change, and can make one.
print('B: bump() in A ->', bump(), '| B sees config.count', config.count, '| A own object frozen:', ownIsFrozen());
config.count = 99;
print('B: wrote config.count = 99, A bump() ->', bump());
print('B: counter inc() ->', inc(), inc(), '| A counter ->', countA());
