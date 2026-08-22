import communicationThreadAPI from '../inbox/communicationThread';

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
};

describe('#CommunicationThreadAPI.meta', () => {
  const originalAxios = window.axios;
  const axiosMock = {
    get: vi.fn(),
  };

  beforeEach(() => {
    window.axios = axiosMock;
    axiosMock.get.mockReset();
    window.history.pushState({}, '', '/app/accounts/43/conversations');
  });

  afterEach(() => {
    window.axios = originalAxios;
    window.history.pushState({}, '', '/');
  });

  it('coalesces identical requests while the first request is in flight', async () => {
    const pending = deferred();
    axiosMock.get.mockReturnValue(pending.promise);

    const firstRequest = communicationThreadAPI.meta({ status: 'open' });
    const secondRequest = communicationThreadAPI.meta({ status: 'open' });

    expect(secondRequest).toBe(firstRequest);
    expect(axiosMock.get).toHaveBeenCalledOnce();
    expect(axiosMock.get).toHaveBeenCalledWith(
      '/api/v1/accounts/43/communication_threads/meta',
      {
        params: expect.objectContaining({ status: 'open' }),
      }
    );

    pending.resolve({ data: { meta: { all_count: 7 } } });
    await expect(firstRequest).resolves.toEqual({
      data: { meta: { all_count: 7 } },
    });
  });

  it('starts a fresh request after the previous request settles', async () => {
    axiosMock.get.mockResolvedValue({ data: { meta: {} } });

    await communicationThreadAPI.meta({ status: 'open' });
    await communicationThreadAPI.meta({ status: 'open' });

    expect(axiosMock.get).toHaveBeenCalledTimes(2);
  });

  it('does not coalesce requests with different filters or account URLs', async () => {
    const pending = [deferred(), deferred(), deferred()];
    axiosMock.get
      .mockReturnValueOnce(pending[0].promise)
      .mockReturnValueOnce(pending[1].promise)
      .mockReturnValueOnce(pending[2].promise);

    const openRequest = communicationThreadAPI.meta({ status: 'open' });
    const pendingRequest = communicationThreadAPI.meta({ status: 'pending' });
    window.history.pushState({}, '', '/app/accounts/44/conversations');
    const otherAccountRequest = communicationThreadAPI.meta({ status: 'open' });

    expect(axiosMock.get).toHaveBeenCalledTimes(3);
    expect(pendingRequest).not.toBe(openRequest);
    expect(otherAccountRequest).not.toBe(openRequest);

    pending.forEach(item => item.resolve({ data: { meta: {} } }));
    await Promise.all([openRequest, pendingRequest, otherAccountRequest]);
  });

  it('clears a rejected request so the next retry reaches the API', async () => {
    const failure = new Error('meta unavailable');
    axiosMock.get
      .mockRejectedValueOnce(failure)
      .mockResolvedValueOnce({ data: { meta: {} } });

    await expect(communicationThreadAPI.meta({ status: 'open' })).rejects.toBe(
      failure
    );
    await expect(
      communicationThreadAPI.meta({ status: 'open' })
    ).resolves.toEqual({ data: { meta: {} } });

    expect(axiosMock.get).toHaveBeenCalledTimes(2);
  });
});
