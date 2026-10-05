import { createSingleFlight } from '../singleFlight';

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
};

describe('#createSingleFlight', () => {
  it('runs a lone call once and passes the result through', async () => {
    const singleFlight = createSingleFlight();
    const run = vi.fn().mockResolvedValue('counts');

    await expect(singleFlight('key', run)).resolves.toBe('counts');

    expect(run).toHaveBeenCalledTimes(1);
  });

  it('does not start a parallel request for overlapping calls with the same key', async () => {
    const singleFlight = createSingleFlight();
    const first = deferred();
    const run = vi
      .fn()
      .mockReturnValueOnce(first.promise)
      .mockResolvedValue('fresh');

    const firstCall = singleFlight('key', run);
    const secondCall = singleFlight('key', run);
    const thirdCall = singleFlight('key', run);
    expect(run).toHaveBeenCalledTimes(1);
    expect(secondCall).toBe(firstCall);
    expect(thirdCall).toBe(firstCall);

    first.resolve('stale');
    await expect(firstCall).resolves.toBe('fresh');
  });

  it('repeats the request once after it settles so joined callers get newer data', async () => {
    const singleFlight = createSingleFlight();
    const first = deferred();
    const run = vi
      .fn()
      .mockReturnValueOnce(first.promise)
      .mockResolvedValue('fresh');

    const firstCall = singleFlight('key', run);
    singleFlight('key', run);
    singleFlight('key', run);
    first.resolve('stale');
    await firstCall;

    // Any number of overlapping calls cost one extra request, not one each.
    expect(run).toHaveBeenCalledTimes(2);
  });

  it('keeps flights with different keys independent', async () => {
    const singleFlight = createSingleFlight();
    const run = vi.fn().mockResolvedValue('counts');

    await Promise.all([singleFlight('a', run), singleFlight('b', run)]);

    expect(run).toHaveBeenCalledTimes(2);
  });

  it('starts a new request when the previous one has already finished', async () => {
    const singleFlight = createSingleFlight();
    const run = vi.fn().mockResolvedValue('counts');

    await singleFlight('key', run);
    await singleFlight('key', run);

    expect(run).toHaveBeenCalledTimes(2);
  });

  it('lets the next call start after a failed request', async () => {
    const singleFlight = createSingleFlight();
    const run = vi
      .fn()
      .mockRejectedValueOnce(new Error('unavailable'))
      .mockResolvedValue('counts');

    await expect(singleFlight('key', run)).rejects.toThrow('unavailable');
    await expect(singleFlight('key', run)).resolves.toBe('counts');
  });
});
