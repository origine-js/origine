// `@engine/std/quansync`: write an operation once, run it synchronously or
// asynchronously. Modeled on https://github.com/quansync-dev/quansync, with one
// difference: a function is indexable by mode name, so a caller that already
// knows its mode (for example from an `io` object) dispatches without branching:
//
//   const stat = quansync({ sync: (io, p) => io.statSync(p), async: (io, p) => io.stat(p) });
//   stat[io.kind](io, path);        // io.kind is 'sync' or 'async'
//
// Two ways to define one:
//
//   quansync({ sync, async })        leaf: two hand-written implementations
//   quansync(function* (...args) {   composite: `yield*` other quansync calls
//     const a = yield* stat(io, p);  (or `yield stat(io, p)`)
//     return a.size;
//   }, { sync?, async? })            optional hand-written fast paths
//
// Every quansync function `f` has:
//   f.sync(...args)    runs synchronously and returns the result (throws on error)
//   f.async(...args)   runs asynchronously and returns a promise
//   f(...args)         a task: usable with `yield*`/`yield` inside a composite,
//                      and awaitable (`await f(...)` runs it asynchronously)
//
// Leaves run with zero overhead: `f.sync` and `f.async` are the implementations
// themselves, so the hot path allocates nothing. Composites cost one generator
// per call, which is why hot operations should supply `{ sync }` fast paths.

const freeze = Object.freeze;

/// A single mode-dependent step yielded by a leaf's generator.
class Effect {
  constructor(sync, async, args) {
    this.sync = sync;
    this.async = async;
    this.args = args;
  }
}

/// A suspended quansync call. It is a generator (so `yield*` works) and a
/// thenable (so `await` works). Single use.
class Task {
  #generator;
  constructor(generator) {
    this.#generator = generator;
  }
  next(value) { return this.#generator.next(value); }
  throw(error) { return this.#generator.throw(error); }
  return(value) { return this.#generator.return(value); }
  [Symbol.iterator]() { return this; }
  then(onFulfilled, onRejected) { return runAsync(this).then(onFulfilled, onRejected); }
}

const isTask = value => value instanceof Task;

function runSync(task) {
  let step = task.next();
  while (!step.done) {
    const yielded = step.value;
    let result;
    try {
      if (yielded instanceof Effect) result = yielded.sync(...yielded.args);
      else if (isTask(yielded)) result = runSync(yielded);
      else throw new TypeError('quansync: only effects and quansync tasks can be yielded');
    } catch (error) {
      step = task.throw(error);
      continue;
    }
    step = task.next(result);
  }
  return step.value;
}

function runAsync(task) {
  return new Promise((resolve, reject) => {
    const advance = (method, argument) => {
      let step;
      try { step = task[method](argument); } catch (error) { reject(error); return; }
      if (step.done) { resolve(step.value); return; }
      const yielded = step.value;
      let pending;
      try {
        if (yielded instanceof Effect) pending = yielded.async(...yielded.args);
        else if (isTask(yielded)) pending = runAsync(yielded);
        else throw new TypeError('quansync: only effects and quansync tasks can be yielded');
      } catch (error) {
        advance('throw', error);
        return;
      }
      Promise.resolve(pending).then(value => advance('next', value), error => advance('throw', error));
    };
    advance('next');
  });
}

export function quansync(definition, overrides) {
  if (typeof definition === 'function') return composite(definition, overrides);
  if (definition !== null && typeof definition === 'object' && typeof definition.sync === 'function' && typeof definition.async === 'function') {
    return leaf(definition.sync, definition.async);
  }
  throw new TypeError('quansync: expected a generator function or { sync, async }');
}

function leaf(syncImpl, asyncImpl) {
  const task = (...args) => new Task((function* () { return yield new Effect(syncImpl, asyncImpl, args); })());
  task.sync = syncImpl;
  task.async = asyncImpl;
  return freeze(task);
}

function composite(generatorFunction, overrides = {}) {
  const task = (...args) => new Task(generatorFunction(...args));
  task.sync = overrides.sync ?? ((...args) => runSync(new Task(generatorFunction(...args))));
  task.async = overrides.async ?? ((...args) => runAsync(new Task(generatorFunction(...args))));
  return freeze(task);
}

/// Runs `task` in `mode` ('sync' | 'async'): a synchronous result or a promise.
export function run(mode, task) {
  if (mode === 'sync') return runSync(task);
  if (mode === 'async') return runAsync(task);
  throw new TypeError("quansync: mode must be 'sync' or 'async'");
}

quansync.run = run;
quansync.isTask = isTask;
quansync.MODES = freeze(['sync', 'async']);
