// The exporter, evaluated in context A. Its exports are data and functions that live in A.
import { inc as incA } from './counter.js';

export const config = { name: 'lib', count: 0 };
export function bump() {
  config.count += 1;
  return config.count;
}
export function ownIsFrozen() {
  return Object.isFrozen(config);
}
export const countA = () => incA();

print('A: lib.js evaluated');
