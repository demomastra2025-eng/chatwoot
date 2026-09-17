import communicationThreadAPI from '../inbox/communicationThread';

const deferred = () => {
  let resolve;
  const promise = new Promise(done => {
    resolve = done;
  });
  return { promise, resolve };
};

describe.each(['get', 'filter'])(
  '#CommunicationThreadAPI.%s single flight',
  method => {
    const originalAxios = window.axios;
    const axiosMock = { get: vi.fn(), post: vi.fn() };
    const params = { page: 4, status: 'open', queryData: { payload: [] } };

    beforeEach(() => {
      window.axios = axiosMock;
      axiosMock.get.mockReset();
      axiosMock.post.mockReset();
      window.history.pushState(
        {},
        '',
        '/app/accounts/43/communication_threads'
      );
    });

    afterEach(() => {
      window.axios = originalAxios;
      window.history.pushState({}, '', '/');
    });

    it('shares only an in-flight request and fetches fresh data after settlement', async () => {
      const pending = deferred();
      const mock = method === 'get' ? axiosMock.get : axiosMock.post;
      mock.mockReturnValue(pending.promise);
      const first = communicationThreadAPI[method](params);
      const duplicate = communicationThreadAPI[method]({ ...params });
      pending.resolve({ data: {} });
      await Promise.all([first, duplicate]);
      expect(mock).toHaveBeenCalledOnce();
      await communicationThreadAPI[method](params);
      expect(mock).toHaveBeenCalledTimes(2);
    });

    it('isolates accounts and pages and allows retry after errors', async () => {
      const mock = method === 'get' ? axiosMock.get : axiosMock.post;
      const pending = deferred();
      mock.mockReturnValue(pending.promise);
      const first = communicationThreadAPI[method](params);
      const nextPage = communicationThreadAPI[method]({ ...params, page: 5 });
      window.history.pushState(
        {},
        '',
        '/app/accounts/44/communication_threads'
      );
      const otherAccount = communicationThreadAPI[method](params);
      pending.resolve({ data: {} });
      await Promise.all([first, nextPage, otherAccount]);
      expect(mock).toHaveBeenCalledTimes(3);
      mock.mockRejectedValueOnce(new Error('unavailable'));
      await expect(communicationThreadAPI[method](params)).rejects.toThrow(
        'unavailable'
      );
      mock.mockResolvedValue({ data: {} });
      await communicationThreadAPI[method](params);
      expect(mock).toHaveBeenCalledTimes(5);
    });

    it('does not reuse a pre-mutation request or let it clear a newer request', async () => {
      const mock = method === 'get' ? axiosMock.get : axiosMock.post;
      const old = deferred();
      const fresh = deferred();
      mock.mockReturnValueOnce(old.promise).mockReturnValueOnce(fresh.promise);
      const oldRequest = communicationThreadAPI[method](params);
      communicationThreadAPI.invalidateListRequests();
      const freshRequest = communicationThreadAPI[method](params);
      old.resolve({ data: { old: true } });
      await oldRequest;
      const duplicate = communicationThreadAPI[method](params);
      expect(mock).toHaveBeenCalledTimes(2);
      fresh.resolve({ data: { fresh: true } });
      await expect(freshRequest).resolves.toEqual({ data: { fresh: true } });
      await expect(duplicate).resolves.toEqual({ data: { fresh: true } });
    });
  }
);

describe('#CommunicationThreadAPI sidebar unread endpoints', () => {
  const originalAxios = window.axios;
  const axiosMock = { get: vi.fn(), post: vi.fn() };

  beforeEach(() => {
    window.axios = axiosMock;
    axiosMock.get.mockReset();
    axiosMock.post.mockReset();
    window.history.pushState({}, '', '/app/accounts/43/communication_threads');
  });

  afterEach(() => {
    window.axios = originalAxios;
    window.history.pushState({}, '', '/');
  });

  it('maps basic thread filters to the lightweight GET endpoint', async () => {
    axiosMock.get.mockResolvedValue({ data: { counts: {} } });

    await communicationThreadAPI.sidebarUnreadCounts({
      status: 'open',
      assigneeType: 'me',
      crmStageId: 12,
    });

    expect(axiosMock.get).toHaveBeenCalledWith(
      '/api/v1/accounts/43/communication_threads/sidebar_unread_counts',
      {
        params: expect.objectContaining({
          status: 'open',
          assignee_type: 'me',
          crm_stage_id: 12,
        }),
      }
    );
  });

  it('sends advanced filters to the lightweight POST endpoint', async () => {
    axiosMock.post.mockResolvedValue({ data: { counts: {} } });
    const queryData = { payload: [{ attribute_key: 'status' }] };

    await communicationThreadAPI.filterSidebarUnreadCounts({
      queryData,
      crmPipelineId: 9,
    });

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/43/communication_threads/filter_sidebar_unread_counts',
      queryData,
      { params: expect.objectContaining({ crm_pipeline_id: 9 }) }
    );
  });
});
