// Sleeps for a minute in its own I/O runtime; the parent terminates it long before that.
export async function main(api) {
  await using io = api.io.create({});
  await io.sleep(60_000);
}
