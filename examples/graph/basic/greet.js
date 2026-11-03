// An imported module. It is evaluated once, before its importer runs.
export const greeting = 'hello from greet.js';
export const info = { file: 'greet.js', tags: ['a', 'b'] };

print('greet.js evaluates first');
