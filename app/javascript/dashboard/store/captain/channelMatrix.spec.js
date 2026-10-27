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

const channelRow = (overrides = {}) => ({
  inbox_id: 5,
  name: 'WhatsApp',
  channel_type: 'Channel::Whatsapp',
  ai_enabled: true,
  auto_reply_mode: 'always',
  ...overrides,
});

const matrixPayload = (overrides = {}) => ({
  channels: [channelRow()],
  assistants: [
    { id: 12, name: 'Admin', active: true, has_card: true, avatar_url: null },
  ],
  ...overrides,
});

const firstAssistantId = store => store.getMatrix?.assistants?.[0]?.id;

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

  it('loads the matrix: channels and agents, with no main agent', async () => {
    getMock.mockResolvedValue({ data: matrixPayload() });
    const store = useCaptainChannelMatrixStore();

    const matrix = await store.fetch();

    expect(matrix.channels.map(channel => channel.inbox_id)).toEqual([5]);
    expect(matrix.assistants).toHaveLength(1);
    expect(matrix).not.toHaveProperty('default_main_assistant_id');
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
      data: matrixPayload({ assistants: [{ id: 30, active: true }] }),
    });
    await pending;
    expect(firstAssistantId(store)).toBe(30);
  });

  it('ignores a slow response for a previous account', async () => {
    const accountOne = deferred();
    getMock.mockReturnValueOnce(accountOne.promise);
    const store = useCaptainChannelMatrixStore();
    const accountOneRequest = store.fetch();

    accountId = '2';
    getMock.mockResolvedValueOnce({
      data: matrixPayload({ assistants: [{ id: 30, active: true }] }),
    });
    await store.fetch();

    accountOne.resolve({ data: matrixPayload() });
    await accountOneRequest;

    expect(firstAssistantId(store)).toBe(30);
  });

  it('saves the channel switches with one PATCH and applies the returned matrix', async () => {
    getMock.mockResolvedValue({ data: matrixPayload() });
    const saved = matrixPayload({
      channels: [channelRow({ ai_enabled: false })],
    });
    updateMock.mockResolvedValue({ data: saved });
    const store = useCaptainChannelMatrixStore();
    await store.fetch();

    const patch = { channels: [{ inbox_id: 5, ai_enabled: false }] };
    const result = await store.save(patch);

    expect(updateMock).toHaveBeenCalledTimes(1);
    expect(updateMock).toHaveBeenCalledWith(patch);
    expect(result).toEqual({ ok: true, matrix: saved });
    expect(store.getMatrix.channels[0].ai_enabled).toBe(false);
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
      data: matrixPayload({ assistants: [{ id: 15, active: true }] }),
    });
    await store.save({ channels: [{ inbox_id: 5, ai_enabled: true }] });

    slowGet.resolve({ data: matrixPayload() });
    await refresh;

    expect(firstAssistantId(store)).toBe(15);
  });

  it('returns the 422 errors and keeps the current matrix', async () => {
    getMock.mockResolvedValue({ data: matrixPayload() });
    const errors = [
      {
        inbox_id: 5,
        assistant_id: null,
        code: 'INVALID_CHANNEL',
        message: 'Channel not found',
      },
    ];
    updateMock.mockRejectedValue({
      response: { status: 422, data: { errors } },
    });
    const store = useCaptainChannelMatrixStore();
    await store.fetch();

    const result = await store.save({
      channels: [{ inbox_id: 5, ai_enabled: true }],
    });

    expect(result).toEqual({ ok: false, errors });
    expect(store.errors).toEqual(errors);
    expect(firstAssistantId(store)).toBe(12);
    expect(store.getUIFlags.isSaving).toBe(false);
  });
});
