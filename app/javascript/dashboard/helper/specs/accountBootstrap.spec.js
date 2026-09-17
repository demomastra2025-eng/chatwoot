import { describe, expect, it, vi } from 'vitest';

import { ensureAccountLoaded } from '../accountBootstrap';

describe('ensureAccountLoaded', () => {
  it('reuses an account already loaded by the route guard', async () => {
    const loadAccounts = vi.fn();

    const loaded = await ensureAccountLoaded({
      accountId: 43,
      getAccount: () => ({ id: 43 }),
      loadAccounts,
    });

    expect(loaded).toBe(false);
    expect(loadAccounts).not.toHaveBeenCalled();
  });

  it('loads the account when it is missing from the store', async () => {
    const loadAccounts = vi.fn().mockResolvedValue();

    const loaded = await ensureAccountLoaded({
      accountId: 43,
      getAccount: () => undefined,
      loadAccounts,
    });

    expect(loaded).toBe(true);
    expect(loadAccounts).toHaveBeenCalledOnce();
  });
});
