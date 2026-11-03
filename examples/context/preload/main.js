// Runs in the realm: it can use what preload gave it and nothing else.
import { eprintln } from 'origine:@std/debug';

globalThis.print('from the realm:', globalThis.greet(globalThis.realmName));
eprintln('realm sees api:', typeof globalThis.api, '; fetch:', typeof globalThis.fetch);
