// Imports from three places: a JSON file (the json provider), a file in the primary root, a file that only the
// fallback root has, and a module a loader serves under a bare name (through an import map).
import { eprintln } from 'origine:@std/debug';
import data from './data.json' with { type: 'json' };
import { local } from './local.js';
import { shared } from './shared.js';
import { greeting } from 'greeting';

eprintln(`json: ${data.name} | local: ${local} | shared: ${shared} | greeting: ${greeting}`);
