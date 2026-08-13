import campaignsAPI from '../campaigns';
import ApiClient from '../ApiClient';

describe('#CampaignsAPI', () => {
  const originalAxios = window.axios;
  const originalPathname = window.location.pathname;
  const axiosMock = {
    post: vi.fn(() => Promise.resolve()),
    get: vi.fn(() => Promise.resolve()),
  };

  beforeEach(() => {
    window.axios = axiosMock;
    window.history.pushState({}, '', '/app/accounts/1/outbound/broadcasts');
  });

  afterEach(() => {
    window.axios = originalAxios;
    window.history.pushState({}, '', originalPathname);
    vi.clearAllMocks();
  });

  it('creates the account-scoped client', () => {
    expect(campaignsAPI).toBeInstanceOf(ApiClient);
  });

  it('uploads a CSV with inbox and country metadata', () => {
    const file = new File(['phone_number\n+77051234567'], 'recipients.csv', {
      type: 'text/csv',
    });

    campaignsAPI.importAudience({
      file,
      inboxId: 17,
      defaultCountry: 'KZ',
    });

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/1/campaign_audience_imports',
      expect.any(FormData),
      { headers: { 'Content-Type': 'multipart/form-data' } }
    );
    const formData = axiosMock.post.mock.calls[0][1];
    expect(formData.get('file')).toBe(file);
    expect(formData.get('inbox_id')).toBe('17');
    expect(formData.get('default_country')).toBe('KZ');
  });

  it('polls by account-scoped numeric import id', () => {
    campaignsAPI.getAudienceImport(42);

    expect(axiosMock.get).toHaveBeenCalledWith(
      '/api/v1/accounts/1/campaign_audience_imports/42'
    );
  });
});
