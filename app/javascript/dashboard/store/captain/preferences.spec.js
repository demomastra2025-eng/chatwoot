import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

const { getMock, updateMock } = vi.hoisted(() => ({
  getMock: vi.fn(),
  updateMock: vi.fn(),
}));

vi.mock('dashboard/api/captain/preferences', () => ({
  default: { get: getMock, updatePreferences: updateMock },
}));

const preferencesAPI = (await import('dashboard/api/captain/preferences'))
  .default;
const { useCaptainConfigStore } = await import('./preferences');
let accountId = '1';

describe('Captain preferences store', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    getMock.mockReset();
    updateMock.mockReset();
    accountId = '1';
    Object.defineProperty(preferencesAPI, 'accountIdFromRoute', {
      configurable: true,
      get: () => accountId,
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('shares an in-flight preferences request between profile forms', async () => {
    let resolveRequest;
    getMock.mockReturnValue(
      new Promise(resolve => {
        resolveRequest = resolve;
      })
    );
    const store = useCaptainConfigStore();

    const first = store.fetch();
    const second = store.fetch();

    expect(getMock).toHaveBeenCalledTimes(1);
    resolveRequest({ data: { features: { assistant: { models: [] } } } });
    await Promise.all([first, second]);
    expect(store.features.assistant.models).toEqual([]);
  });

  it('uses a short account-scoped cache and supports explicit revalidation', async () => {
    let now = 1000;
    vi.spyOn(Date, 'now').mockImplementation(() => now);
    getMock.mockResolvedValue({ data: { features: { editor: { enabled: true } } } });
    const store = useCaptainConfigStore();

    await store.fetch();
    await store.fetch();
    expect(getMock).toHaveBeenCalledOnce();

    await store.fetch({ force: true });
    expect(getMock).toHaveBeenCalledTimes(2);

    now += 31_000;
    await store.fetch();
    expect(getMock).toHaveBeenCalledTimes(3);
  });

  it('upgrades a client-metadata request to a full request for the same account', async () => {
    getMock
      .mockResolvedValueOnce({ data: { features: { editor: { enabled: false } } } })
      .mockResolvedValueOnce({ data: { features: { editor: { enabled: true } } } });
    const store = useCaptainConfigStore();

    await store.fetch({ clientMetadataOnly: true });
    await store.fetch();

    expect(getMock).toHaveBeenNthCalledWith(1, { client_metadata_only: true });
    expect(getMock).toHaveBeenNthCalledWith(2, { client_metadata_only: false });
    expect(store.features.editor.enabled).toBe(true);
  });

  it('allows a client-metadata fetch to retry after a failed request', async () => {
    getMock
      .mockRejectedValueOnce(new Error('temporary failure'))
      .mockResolvedValueOnce({
        data: { features: { editor: { enabled: true } } },
      });
    const store = useCaptainConfigStore();

    await store.fetch({ clientMetadataOnly: true });

    expect(store.uiFlags.fetchError).toBe(true);
    expect(getMock).toHaveBeenCalledTimes(1);

    await store.fetch({ clientMetadataOnly: true });

    expect(getMock).toHaveBeenCalledTimes(2);
    expect(store.uiFlags.fetchError).toBe(false);
    expect(store.features.editor.enabled).toBe(true);
  });

  it('does not apply a slow response after the active account changes', async () => {
    let resolveAccountOne;
    getMock.mockReturnValueOnce(
      new Promise(resolve => {
        resolveAccountOne = resolve;
      })
    );
    const store = useCaptainConfigStore();
    const accountOneRequest = store.fetch();

    accountId = '2';
    let resolveAccountTwo;
    getMock.mockReturnValueOnce(
      new Promise(resolve => {
        resolveAccountTwo = resolve;
      })
    );
    const accountTwoRequest = store.fetch();

    expect(store.activePreferencesAccountId).toBe('2');
    expect(store.features).toEqual({});
    expect(store.uiFlags.isFetching).toBe(true);

    resolveAccountTwo({
      data: { features: { editor: { enabled: false } } },
    });
    await accountTwoRequest;

    expect(store.uiFlags.isFetching).toBe(false);

    resolveAccountOne({
      data: { features: { editor: { enabled: true } } },
    });
    await accountOneRequest;

    expect(store.activePreferencesAccountId).toBe('2');
    expect(store.features.editor.enabled).toBe(false);
  });

  it('does not apply an update response to a different workspace after navigation', async () => {
    let resolveUpdate;
    updateMock.mockReturnValue(
      new Promise(resolve => {
        resolveUpdate = resolve;
      })
    );
    const store = useCaptainConfigStore();
    store.applyPayload({ features: { editor: { enabled: false } } });
    store.activePreferencesAccountId = '1';

    const updateRequest = store.updatePreferences({ captain_features: {} });
    accountId = '2';
    getMock.mockResolvedValueOnce({
      data: { features: { editor: { enabled: true } } },
    });
    await store.fetch();

    resolveUpdate({
      data: { features: { editor: { enabled: false } } },
    });
    await updateRequest;

    expect(store.features.editor.enabled).toBe(true);
    expect(store.activePreferencesAccountId).toBe('2');
  });
});
