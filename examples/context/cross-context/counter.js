// Each context that loads this file gets its own module, with its own state (`n`).
let n = 0;
export function inc() {
  n += 1;
  return n;
}

print('counter.js evaluated');
