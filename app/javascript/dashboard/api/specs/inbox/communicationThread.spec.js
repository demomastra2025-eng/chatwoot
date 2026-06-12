import communicationThreadAPI from '../../inbox/communicationThread';
import ApiClient from '../../ApiClient';

describe('#CommunicationThreadAPI', () => {
  it('creates correct instance', () => {
    expect(communicationThreadAPI).toBeInstanceOf(ApiClient);
    expect(communicationThreadAPI).toHaveProperty('markMessageRead');
  });

  describe('API calls', () => {
    const originalAxios = window.axios;
    const axiosMock = {
      post: vi.fn(() => Promise.resolve()),
      get: vi.fn(() => Promise.resolve()),
    };

    beforeEach(() => {
      window.axios = axiosMock;
    });

    afterEach(() => {
      window.axios = originalAxios;
      vi.clearAllMocks();
    });

    it('#markMessageRead', () => {
      communicationThreadAPI.markMessageRead({ id: 7 });

      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/communication_threads/7/update_last_seen'
      );
    });
  });
});
