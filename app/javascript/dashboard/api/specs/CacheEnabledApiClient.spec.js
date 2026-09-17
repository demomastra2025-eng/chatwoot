import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { getAccountCacheKeys } from '../CacheEnabledApiClient';

describe('getAccountCacheKeys', () => {
  const originalAxios = window.axios;

  beforeEach(() => {
    window.axios = { get: vi.fn() };
  });

  afterEach(() => {
    window.axios = originalAxios;
  });

  it('shares an in-flight request for the same account', async () => {
    let resolveRequest;
    window.axios.get.mockReturnValue(
      new Promise(resolve => {
        resolveRequest = resolve;
      })
    );

    const firstRequest = getAccountCacheKeys(43);
    const secondRequest = getAccountCacheKeys(43);

    expect(window.axios.get).toHaveBeenCalledOnce();
    expect(secondRequest).toBe(firstRequest);

    resolveRequest({ data: { cache_keys: { inbox: 'inbox-key' } } });
    await expect(firstRequest).resolves.toEqual({
      data: { cache_keys: { inbox: 'inbox-key' } },
    });
  });

  it('keeps in-flight requests isolated by account', async () => {
    window.axios.get.mockResolvedValue({ data: { cache_keys: {} } });

    await Promise.all([getAccountCacheKeys(43), getAccountCacheKeys(44)]);

    expect(window.axios.get).toHaveBeenCalledTimes(2);
    expect(window.axios.get).toHaveBeenCalledWith(
      '/api/v1/accounts/43/cache_keys'
    );
    expect(window.axios.get).toHaveBeenCalledWith(
      '/api/v1/accounts/44/cache_keys'
    );
  });

  it('retries after a failed request', async () => {
    window.axios.get.mockRejectedValueOnce(new Error('network error'));

    await expect(getAccountCacheKeys(43)).rejects.toThrow('network error');

    window.axios.get.mockResolvedValueOnce({ data: { cache_keys: {} } });
    await expect(getAccountCacheKeys(43)).resolves.toEqual({
      data: { cache_keys: {} },
    });
    expect(window.axios.get).toHaveBeenCalledTimes(2);
  });
});
