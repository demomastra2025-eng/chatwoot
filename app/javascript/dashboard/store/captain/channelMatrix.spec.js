import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

const { getMock, updateMock } = vi.hoisted(() => ({
  getMock: vi.fn(),
  updateMock: vi.fn(),
}));

vi.mock('dashboard/api/captain/channelMatrix', () => ({
  default: { get: getMock, update: updateMock },
}));

const channelMatrixAPI = (await import('dashboard/api/captain/channelMatrix'))
  .default;
const { useCaptainChannelMatrixStore } = await import('./channelMatrix');
let accountId = '1';

const matrixPayload = (overrides = {}) => ({
  default_main_assistant_id: 12,
  channels: [
    {
      inbox_id: 5,
      name: 'WhatsApp',
      channel_type: 'Channel::Whatsapp',
      ai_enabled: true,
      main_assistant_id: 12,
      assistant_ids: [12],
      auto_reply_mode: 'always',
    },
    {
      inbox_id: 9,
      name: 'Calls',
      channel_type: 'Channel::Voice',
      ai_enabled: true,
      main_assistant_id: 12,
      assistant_ids: [12],
      auto_reply_mode: 'always',
    },
  ],
  assistants: [{ id: 12, name: 'Admin', active: true, channel_scope: 'all' }],
  ...overrides,
});

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
};

describe('Captain channel matrix store', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    getMock.mockReset();
    updateMock.mockReset();
    accountId = '1';
    Object.defineProperty(channelMatrixAPI, 'accountIdFromRoute', {
      configurable: true,
      get: () => accountId,
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('loads the matrix and exposes text channels only', async () => {
    getMock.mockResolvedValue({ data: matrixPayload() });
    const store = useCaptainChannelMatrixStore();

    const matrix = await store.fetch();

    expect(matrix.default_main_assistant_id).toBe(12);
    expect(store.getChannels.map(channel => channel.inbox_id)).toEqual([5]);
    expect(store.getAssistants).toHaveLength(1);
    expect(store.getDefaultMainAssistantId).toBe(12);
    expect(store.getUIFlags).toMatchObject({
      isFetching: false,
      fetchError: false,
    });
  });

  it('shares an in-flight request and caches it for a short time', async () => {
    let now = 1000;
    vi.spyOn(Date, 'now').mockImplementation(() => now);
    const request = deferred();
    getMock.mockReturnValue(request.promise);
    const store = useCaptainChannelMatrixStore();

    const first = store.fetch();
    const second = store.fetch();
    expect(getMock).toHaveBeenCalledTimes(1);
    expect(store.getUIFlags.isFetching).toBe(true);

    request.resolve({ data: matrixPayload() });
    await Promise.all([first, second]);
    await store.fetch();
    expect(getMock).toHaveBeenCalledTimes(1);

    getMock.mockResolvedValue({ data: matrixPayload() });
    await store.fetch({ force: true });
    expect(getMock).toHaveBeenCalledTimes(2);

    now += 31_000;
    await store.fetch();
    expect(getMock).toHaveBeenCalledTimes(3);
  });

  it('never throws: a 403 sets the fetch error flag', async () => {
    getMock.mockRejectedValue({ response: { status: 403 } });
    const store = useCaptainChannelMatrixStore();

    await expect(store.fetch()).resolves.toBeNull();
    expect(store.getUIFlags.fetchError).toBe(true);
    expect(store.getMatrix).toBeNull();
  });

  it('resets and refetches when the account changes', async () => {
    getMock.mockResolvedValueOnce({ data: matrixPayload() });
    const store = useCaptainChannelMatrixStore();
    await store.fetch();

    accountId = '2';
    const request = deferred();
    getMock.mockReturnValueOnce(request.promise);
    const pending = store.fetch();

    expect(store.getMatrix).toBeNull();
    expect(getMock).toHaveBeenCalledTimes(2);

    request.resolve({
      data: matrixPayload({ default_main_assistant_id: 30 }),
    });
    await pending;
    expect(store.getDefaultMainAssistantId).toBe(30);
  });

  it('ignores a slow response for a previous account', async () => {
    const accountOne = deferred();
    getMock.mockReturnValueOnce(accountOne.promise);
    const store = useCaptainChannelMatrixStore();
    const accountOneRequest = store.fetch();

    accountId = '2';
    getMock.mockResolvedValueOnce({
      data: matrixPayload({ default_main_assistant_id: 30 }),
    });
    await store.fetch();

    accountOne.resolve({ data: matrixPayload() });
    await accountOneRequest;

    expect(store.getDefaultMainAssistantId).toBe(30);
  });

  it('saves with one PATCH and applies the returned matrix', async () => {
    getMock.mockResolvedValue({ data: matrixPayload() });
    const saved = matrixPayload({ default_main_assistant_id: 15 });
    updateMock.mockResolvedValue({ data: saved });
    const store = useCaptainChannelMatrixStore();
    await store.fetch();

    const result = await store.save({ default_main_assistant_id: 15 });

    expect(updateMock).toHaveBeenCalledTimes(1);
    expect(updateMock).toHaveBeenCalledWith({ default_main_assistant_id: 15 });
    expect(result).toEqual({ ok: true, matrix: saved });
    expect(store.getDefaultMainAssistantId).toBe(15);
    expect(store.getUIFlags.isSaving).toBe(false);
  });

  it('does not let an older GET overwrite a saved matrix', async () => {
    getMock.mockResolvedValueOnce({ data: matrixPayload() });
    const store = useCaptainChannelMatrixStore();
    await store.fetch();

    const slowGet = deferred();
    getMock.mockReturnValueOnce(slowGet.promise);
    const refresh = store.fetch({ force: true });
    updateMock.mockResolvedValue({
      data: matrixPayload({ default_main_assistant_id: 15 }),
    });
    await store.save({ default_main_assistant_id: 15 });

    slowGet.resolve({ data: matrixPayload() });
    await refresh;

    expect(store.getDefaultMainAssistantId).toBe(15);
  });

  it('returns the 422 errors and keeps the current matrix', async () => {
    getMock.mockResolvedValue({ data: matrixPayload() });
    const errors = [
      {
        inbox_id: 5,
        assistant_id: null,
        code: 'MAIN_AGENT_REQUIRED',
        message: 'Choose a main agent',
      },
    ];
    updateMock.mockRejectedValue({
      response: { status: 422, data: { errors } },
    });
    const store = useCaptainChannelMatrixStore();
    await store.fetch();

    const result = await store.save({
      channels: [{ inbox_id: 5, ai_enabled: true, main_assistant_id: null }],
    });

    expect(result).toEqual({ ok: false, errors });
    expect(store.errors).toEqual(errors);
    expect(store.getDefaultMainAssistantId).toBe(12);
    expect(store.getUIFlags.isSaving).toBe(false);
  });
});
