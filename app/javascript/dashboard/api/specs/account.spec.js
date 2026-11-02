import accountAPI from '../account';
import ApiClient from '../ApiClient';

describe('#accountAPI', () => {
  it('creates correct instance', () => {
    expect(accountAPI).toBeInstanceOf(ApiClient);
    expect(accountAPI).toHaveProperty('get');
    expect(accountAPI).toHaveProperty('show');
    expect(accountAPI).toHaveProperty('create');
    expect(accountAPI).toHaveProperty('update');
    expect(accountAPI).toHaveProperty('delete');
    expect(accountAPI).toHaveProperty('createAccount');
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
    });

    afterEach(() => {
      window.axios = originalAxios;
      vi.restoreAllMocks();
    });

    it('honors the explicitly selected account when another account is open', async () => {
      vi.spyOn(accountAPI, 'currentAccountUrl', 'get').mockReturnValue(
        '/api/v1/accounts/1'
      );
      await accountAPI.update(2, { name: 'Selected branch' });
      expect(axiosMock.patch).toHaveBeenCalledWith('/api/v1/accounts/2', {
        name: 'Selected branch',
      });
    });

    it('uses the same explicit account for logo uploads', async () => {
      vi.spyOn(accountAPI, 'currentAccountUrl', 'get').mockReturnValue(
        '/api/v1/accounts/1'
      );
      const logo = new File(['image'], 'logo.png', { type: 'image/png' });
      await accountAPI.update(2, { logo, name: 'Selected branch' });
      const [url, body] = axiosMock.patch.mock.calls[0];
      expect(url).toBe('/api/v1/accounts/2');
      expect(body).toBeInstanceOf(FormData);
      expect(body.get('logo')).toBe(logo);
    });

    it('preserves updates of the active account when no ID is supplied', async () => {
      vi.spyOn(accountAPI, 'currentAccountUrl', 'get').mockReturnValue(
        '/api/v1/accounts/1'
      );
      await accountAPI.update(undefined, { name: 'Active branch' });
      expect(axiosMock.patch).toHaveBeenCalledWith('/api/v1/accounts/1', {
        name: 'Active branch',
      });
    });

    it('waits for one company update before requesting its next snapshot', async () => {
      let finish;
      axiosMock.patch.mockImplementationOnce(
        () =>
          new Promise(resolve => {
            finish = resolve;
          })
      );
      const first = accountAPI.update(2, {
        workspace_greeting: { message: 'New' },
      });
      const second = accountAPI.update(2, {
        workspace_out_of_office: { message: 'Closed' },
      });
      expect(axiosMock.patch).toHaveBeenCalledTimes(1);
      finish({ data: { id: 2 } });
      await Promise.all([first, second]);
      expect(axiosMock.patch).toHaveBeenCalledTimes(2);
      expect(axiosMock.patch.mock.calls[1][1]).toEqual({
        workspace_out_of_office: { message: 'Closed' },
      });
    });

    it('continues pending saves after an earlier request fails', async () => {
      let fail;
      axiosMock.patch.mockImplementationOnce(
        () =>
          new Promise((resolve, reject) => {
            fail = reject;
          })
      );
      const first = accountAPI.update(2, { name: 'Failed' });
      const rejection = expect(first).rejects.toThrow('Offline');
      const second = accountAPI.update(2, { name: 'Next' });
      fail(new Error('Offline'));
      await rejection;
      await second;
      expect(axiosMock.patch).toHaveBeenLastCalledWith('/api/v1/accounts/2', {
        name: 'Next',
      });
    });

    it('does not block an independent company behind another company save', async () => {
      let finish;
      axiosMock.patch.mockImplementationOnce(
        () =>
          new Promise(resolve => {
            finish = resolve;
          })
      );
      const first = accountAPI.update(2, { name: 'Pending' });
      await accountAPI.update(3, { name: 'Independent' });
      expect(axiosMock.patch).toHaveBeenLastCalledWith('/api/v1/accounts/3', {
        name: 'Independent',
      });
      finish({ data: { id: 2 } });
      await first;
    });

    it('#createAccount', () => {
      accountAPI.createAccount({
        name: 'Chatwoot',
      });
      expect(axiosMock.post).toHaveBeenCalledWith('/api/v1/accounts', {
        name: 'Chatwoot',
      });
    });
  });
});
