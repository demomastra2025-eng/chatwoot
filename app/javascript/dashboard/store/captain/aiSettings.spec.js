import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

const { getMock, updateMock } = vi.hoisted(() => ({
  getMock: vi.fn(),
  updateMock: vi.fn(),
}));

vi.mock('dashboard/api/captain/aiSettings', () => ({
  default: { get: getMock, update: updateMock },
}));

const aiSettingsAPI = (await import('dashboard/api/captain/aiSettings'))
  .default;
const { useCaptainAiSettingsStore } = await import('./aiSettings');
let accountId = '1';

const payload = (changes = {}) => ({
  understanding: { voice_messages: true, web_search: false },
  faq: { generate_from_resolved: false },
  availability: { web_access_configured: true },
  ...changes,
});

const httpError = (status, data) =>
  Object.assign(new Error(`Request failed with status code ${status}`), {
    response: { status, data },
  });

describe('Captain AI settings store', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    getMock.mockReset();
    updateMock.mockReset();
    accountId = '1';
    Object.defineProperty(aiSettingsAPI, 'accountIdFromRoute', {
      configurable: true,
      get: () => accountId,
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('loads the raw payload including availability', async () => {
    getMock.mockResolvedValue({ data: payload() });
    const store = useCaptainAiSettingsStore();

    const result = await store.fetch();

    expect(result).toEqual(payload());
    expect(store.getSettings).toEqual(payload());
    expect(store.getAvailability).toEqual({ web_access_configured: true });
    expect(store.getUIFlags.isFetching).toBe(false);
  });

  it('shares an in-flight request and caches it for thirty seconds', async () => {
    let now = 1000;
    vi.spyOn(Date, 'now').mockImplementation(() => now);
    let resolveRequest;
    getMock.mockReturnValueOnce(
      new Promise(resolve => {
        resolveRequest = resolve;
      })
    );
    const store = useCaptainAiSettingsStore();

    const first = store.fetch();
    const second = store.fetch();
    expect(store.uiFlags.isFetching).toBe(true);
    resolveRequest({ data: payload() });
    await Promise.all([first, second]);
    expect(getMock).toHaveBeenCalledTimes(1);

    await store.fetch();
    expect(getMock).toHaveBeenCalledTimes(1);

    getMock.mockResolvedValue({ data: payload() });
    await store.fetch({ force: true });
    expect(getMock).toHaveBeenCalledTimes(2);

    now += 31_000;
    await store.fetch();
    expect(getMock).toHaveBeenCalledTimes(3);
  });

  it('never throws and flags a forbidden request', async () => {
    getMock.mockRejectedValue(httpError(403, { error: 'Forbidden' }));
    const store = useCaptainAiSettingsStore();

    await expect(store.fetch()).resolves.toBeNull();
    expect(store.uiFlags.fetchError).toBe(true);
    expect(store.errors).toEqual([
      { field: null, code: 'http_403', message: 'Forbidden' },
    ]);
  });

  it('drops the previous workspace and ignores its slow response', async () => {
    let resolveAccountOne;
    getMock.mockReturnValueOnce(
      new Promise(resolve => {
        resolveAccountOne = resolve;
      })
    );
    const store = useCaptainAiSettingsStore();
    const accountOneRequest = store.fetch();

    accountId = '2';
    getMock.mockResolvedValueOnce({
      data: payload({ faq: { generate_from_resolved: true } }),
    });
    await store.fetch();
    resolveAccountOne({ data: payload() });
    await accountOneRequest;

    expect(store.accountId).toBe('2');
    expect(store.settings.faq.generate_from_resolved).toBe(true);
  });

  it('saves a partial payload and keeps the full settings', async () => {
    getMock.mockResolvedValue({ data: payload() });
    updateMock.mockResolvedValue({
      data: payload({ faq: { generate_from_resolved: true } }),
    });
    const store = useCaptainAiSettingsStore();
    await store.fetch();

    const result = await store.save({ faq: { generate_from_resolved: true } });

    expect(updateMock).toHaveBeenCalledWith({
      faq: { generate_from_resolved: true },
    });
    expect(result.ok).toBe(true);
    expect(result.settings.faq.generate_from_resolved).toBe(true);
    expect(store.settings.availability).toEqual({
      web_access_configured: true,
    });
    expect(store.uiFlags.isSaving).toBe(false);
  });

  it('merges the sent sections when the response has no settings body', async () => {
    getMock.mockResolvedValue({ data: payload() });
    updateMock.mockResolvedValue({ data: { ok: true } });
    const store = useCaptainAiSettingsStore();
    await store.fetch();

    const result = await store.save({
      conversation: { message_collapse_window_seconds: 5 },
    });

    expect(result.ok).toBe(true);
    expect(store.settings.conversation).toEqual({
      message_collapse_window_seconds: 5,
    });
    expect(store.settings.understanding).toEqual(payload().understanding);
  });

  it('returns the 422 field errors instead of throwing', async () => {
    const errors = [
      {
        field: 'safety.custom_rules[0].name',
        code: 'blank',
        message: 'must not be blank',
      },
    ];
    updateMock.mockRejectedValue(httpError(422, { errors }));
    const store = useCaptainAiSettingsStore();

    const result = await store.save({ safety: { custom_rules: [] } });

    expect(result).toEqual({ ok: false, errors });
    expect(store.errors).toEqual(errors);
    expect(store.uiFlags.isSaving).toBe(false);
  });

  it('turns a network failure into one general error', async () => {
    updateMock.mockRejectedValue(new Error('Network Error'));
    const store = useCaptainAiSettingsStore();

    const result = await store.save({ faq: {} });

    expect(result).toEqual({
      ok: false,
      errors: [
        { field: null, code: 'network_error', message: 'Network Error' },
      ],
    });
  });
});
