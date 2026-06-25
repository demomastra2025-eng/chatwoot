import inboxesAPI from '../inboxes';
import ApiClient from '../ApiClient';

describe('#InboxesAPI', () => {
  it('creates correct instance', () => {
    expect(inboxesAPI).toBeInstanceOf(ApiClient);
    expect(inboxesAPI).toHaveProperty('get');
    expect(inboxesAPI).toHaveProperty('show');
    expect(inboxesAPI).toHaveProperty('create');
    expect(inboxesAPI).toHaveProperty('update');
    expect(inboxesAPI).toHaveProperty('delete');
    expect(inboxesAPI).toHaveProperty('getCampaigns');
    expect(inboxesAPI).toHaveProperty('getAgentBot');
    expect(inboxesAPI).toHaveProperty('setAgentBot');
    expect(inboxesAPI).toHaveProperty('syncTemplates');
    expect(inboxesAPI).toHaveProperty('createWhatsAppTemplate');
    expect(inboxesAPI).toHaveProperty('deleteWhatsAppTemplate');
  });

  describe('API calls', () => {
    const originalAxios = window.axios;
    const axiosMock = {
      post: vi.fn(() => Promise.resolve()),
      get: vi.fn(() => Promise.resolve()),
      patch: vi.fn(() => Promise.resolve()),
      delete: vi.fn(() => Promise.resolve()),
    };

    beforeEach(() => {
      window.axios = axiosMock;
      Object.values(axiosMock).forEach(mock => mock.mockClear());
    });

    afterEach(() => {
      window.axios = originalAxios;
      window.history.pushState({}, '', '/');
    });

    it('#getCampaigns', () => {
      inboxesAPI.getCampaigns(2);
      expect(axiosMock.get).toHaveBeenCalledWith('/api/v1/inboxes/2/campaigns');
    });

    it('#deleteInboxAvatar', () => {
      inboxesAPI.deleteInboxAvatar(2);
      expect(axiosMock.delete).toHaveBeenCalledWith('/api/v1/inboxes/2/avatar');
    });

    it('#syncTemplates', () => {
      inboxesAPI.syncTemplates(2);
      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/sync_templates'
      );
    });

    it('#createWhatsAppTemplate', () => {
      const template = { name: 'order_update' };
      inboxesAPI.createWhatsAppTemplate(2, template);
      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/whatsapp_templates',
        { template }
      );
    });

    it('#deleteWhatsAppTemplate', () => {
      inboxesAPI.deleteWhatsAppTemplate(2, 'order_update');
      expect(axiosMock.delete).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/whatsapp_templates/order_update'
      );
    });

    it('does not reuse cached inboxes after route account changes', async () => {
      window.history.pushState({}, '', '/app/accounts/6/settings/inboxes');
      axiosMock.get.mockImplementation(url => {
        if (url === '/api/v1/accounts/6/cache_keys') {
          return Promise.resolve({
            data: { cache_keys: { inbox: 'same-key' } },
          });
        }
        if (url === '/api/v1/accounts/6/inboxes') {
          return Promise.resolve({
            data: { payload: [{ id: 57, name: 'account 6 inbox' }] },
          });
        }
        return Promise.reject(new Error('Unexpected request: ' + url));
      });

      await inboxesAPI.get(true);

      window.history.pushState({}, '', '/app/accounts/64/settings/inboxes');
      axiosMock.get.mockClear();
      axiosMock.get.mockImplementation(url => {
        if (url === '/api/v1/accounts/64/cache_keys') {
          return Promise.resolve({
            data: { cache_keys: { inbox: 'same-key' } },
          });
        }
        if (url === '/api/v1/accounts/64/inboxes') {
          return Promise.resolve({
            data: { payload: [{ id: 154, name: 'account 64 inbox' }] },
          });
        }
        return Promise.reject(new Error('Unexpected request: ' + url));
      });

      const response = await inboxesAPI.get(true);

      expect(response.data.payload).toEqual([
        { id: 154, name: 'account 64 inbox' },
      ]);
      expect(axiosMock.get).toHaveBeenCalledWith('/api/v1/accounts/64/inboxes');
    });

    it('does not use local cache when the API omits the model cache key', async () => {
      window.history.pushState({}, '', '/app/accounts/65/settings/inboxes');
      axiosMock.get.mockImplementation(url => {
        if (url === '/api/v1/accounts/65/cache_keys') {
          return Promise.resolve({ data: { cache_keys: {} } });
        }
        if (url === '/api/v1/accounts/65/inboxes') {
          return Promise.resolve({
            data: { payload: [{ id: 155, name: 'fresh inbox' }] },
          });
        }
        return Promise.reject(new Error('Unexpected request: ' + url));
      });

      const response = await inboxesAPI.get(true);

      expect(response.data.payload).toEqual([{ id: 155, name: 'fresh inbox' }]);
      expect(axiosMock.get).toHaveBeenCalledWith('/api/v1/accounts/65/inboxes');
    });

    it('uses the started account for network fallback when cache init fails after a route change', async () => {
      let rejectInitDb;
      const initDbPromise = new Promise((_, reject) => {
        rejectInitDb = reject;
      });
      const getDataManagerSpy = vi.spyOn(inboxesAPI, 'getDataManager');
      getDataManagerSpy.mockReturnValue({
        initDb: vi.fn(() => initDbPromise),
      });

      try {
        window.history.pushState({}, '', '/app/accounts/5007/settings/inboxes');
        axiosMock.get.mockImplementation(url => {
          if (url === '/api/v1/accounts/5007/inboxes') {
            return Promise.resolve({
              data: { payload: [{ id: 5007, name: 'started account inbox' }] },
            });
          }
          return Promise.reject(new Error('Unexpected request: ' + url));
        });

        const request = inboxesAPI.get(true);
        window.history.pushState({}, '', '/app/accounts/5064/settings/inboxes');
        rejectInitDb(new Error('IndexedDB unavailable'));

        const response = await request;

        expect(response.data.payload).toEqual([
          { id: 5007, name: 'started account inbox' },
        ]);
        expect(axiosMock.get).toHaveBeenCalledWith(
          '/api/v1/accounts/5007/inboxes'
        );
      } finally {
        getDataManagerSpy.mockRestore();
      }
    });

    it('writes refreshed cache to the account that started the request', async () => {
      let resolveNetwork;
      const startedAccountPayload = [
        { id: 5006, name: 'started account inbox' },
      ];

      window.history.pushState({}, '', '/app/accounts/5006/settings/inboxes');
      axiosMock.get.mockImplementation(url => {
        if (url === '/api/v1/accounts/5006/cache_keys') {
          return Promise.resolve({ data: { cache_keys: {} } });
        }
        if (url === '/api/v1/accounts/5006/inboxes') {
          return new Promise(resolve => {
            resolveNetwork = resolve;
          });
        }
        return Promise.reject(new Error('Unexpected request: ' + url));
      });

      const request = inboxesAPI.get(true);
      // Let IndexedDB init and cache-key request finish before changing route.
      await vi.waitFor(() =>
        expect(resolveNetwork).toEqual(expect.any(Function))
      );
      window.history.pushState({}, '', '/app/accounts/5064/settings/inboxes');

      resolveNetwork({ data: { payload: startedAccountPayload } });
      const response = await request;

      const startedAccountDataManager = inboxesAPI.getDataManager('5006');
      await startedAccountDataManager.initDb();
      const currentAccountDataManager = inboxesAPI.getDataManager('5064');
      await currentAccountDataManager.initDb();

      expect(response.data.payload).toEqual(startedAccountPayload);
      expect(
        await startedAccountDataManager.get({ modelName: 'inbox' })
      ).toEqual(startedAccountPayload);
      expect(
        await currentAccountDataManager.get({ modelName: 'inbox' })
      ).toEqual([]);
    });
  });
});
