import { eprintln } from 'origine:@std/debug';
import { side } from './side.js';
export const message = `main.js with ${side}`;
eprintln('main.js evaluates');
