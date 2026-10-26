/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const io = api.io.create();
  try {
    // Schedule against a monotonic deadline, independent of wall-clock changes.
    const deadline = io.now() + 10;
    await io.sleepUntil(deadline);

    const timer = io.timer(60_000);
    const canceled = timer.promise.then(
      () => false,
      error => error.name === 'Canceled',
    );
    timer.cancel();
    if (!(await canceled)) throw new Error('timer was not canceled');
    await io.sleep(1);
  } finally {
    await io.close();
  }
}
