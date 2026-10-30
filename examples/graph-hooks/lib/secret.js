// Denied by the policy hook: it must never be read or evaluated.
export const secret = 'do not load';
print('secret.js evaluated (this must not print)');
