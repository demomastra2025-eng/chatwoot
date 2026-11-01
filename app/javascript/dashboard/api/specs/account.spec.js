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

    it('honors the explicitly selected account when another account is open', () => {
      vi.spyOn(accountAPI, 'currentAccountUrl', 'get').mockReturnValue(
        '/api/v1/accounts/1'
      );
      accountAPI.update(2, { name: 'Selected branch' });
      expect(axiosMock.patch).toHaveBeenCalledWith('/api/v1/accounts/2', {
        name: 'Selected branch',
      });
    });

    it('uses the same explicit account for logo uploads', () => {
      vi.spyOn(accountAPI, 'currentAccountUrl', 'get').mockReturnValue(
        '/api/v1/accounts/1'
      );
      const logo = new File(['image'], 'logo.png', { type: 'image/png' });
      accountAPI.update(2, { logo, name: 'Selected branch' });
      const [url, body] = axiosMock.patch.mock.calls[0];
      expect(url).toBe('/api/v1/accounts/2');
      expect(body).toBeInstanceOf(FormData);
      expect(body.get('logo')).toBe(logo);
    });

    it('preserves updates of the active account when no ID is supplied', () => {
      vi.spyOn(accountAPI, 'currentAccountUrl', 'get').mockReturnValue(
        '/api/v1/accounts/1'
      );
      accountAPI.update(undefined, { name: 'Active branch' });
      expect(axiosMock.patch).toHaveBeenCalledWith('/api/v1/accounts/1', {
        name: 'Active branch',
      });
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
