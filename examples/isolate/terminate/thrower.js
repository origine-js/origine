// Fails: an error thrown by main makes the isolate 'failed', and join reports the error's name.
export async function main() {
  throw new Error('thrown on purpose');
}
