import { describe, expect, it, vi } from 'vitest';

import {
  createLatestRequestGuard,
  runLatestRequestRetries,
} from './latestRequestGuard';

describe('createLatestRequestGuard', () => {
  it('invalidates an older request when a newer request starts', () => {
    const guard = createLatestRequestGuard();
    const firstRequestId = guard.start();
    const secondRequestId = guard.start();

    expect(guard.isCurrent(firstRequestId)).toBe(false);
    expect(guard.isCurrent(secondRequestId)).toBe(true);
  });

  it('does not retry after the request becomes stale while waiting', async () => {
    let isCurrent = true;
    const load = vi.fn();

    await runLatestRequestRetries({
      attempts: 3,
      isCurrent: () => isCurrent,
      load,
      shouldRetry: () => true,
      wait: () => {
        isCurrent = false;
      },
    });

    expect(load).toHaveBeenCalledTimes(1);
  });
});
