import personDialogAPI from '../personDialog';
import ApiClient from '../ApiClient';

describe('#PersonDialogAPI', () => {
  it('creates a new instance of the class', () => {
    expect(personDialogAPI).toBeInstanceOf(ApiClient);
    expect(personDialogAPI).toHaveProperty('show');
    expect(personDialogAPI).toHaveProperty('createMessage');
  });

  describe('API calls', () => {
    const originalAxios = window.axios;
    const axiosMock = Object.assign(vi.fn().mockResolvedValue({ data: {} }), {
      get: vi.fn(() => Promise.resolve({ data: {} })),
    });

    beforeEach(() => {
      window.axios = axiosMock;
      axiosMock.mockClear();
      axiosMock.get.mockClear();
      window.history.pushState({}, '', '/app/accounts/43/conversations');
    });

    afterEach(() => {
      window.axios = originalAxios;
      window.history.pushState({}, '', '/');
    });

    it('reads the dialog of a person without writing', () => {
      personDialogAPI.show(5);

      expect(axiosMock.get).toHaveBeenCalledWith(
        '/api/v1/accounts/43/contacts/5/dialog'
      );
    });

    it('posts the first message to the person with its echo_id', () => {
      personDialogAPI.createMessage(5, {
        message: 'Hello',
        echo_id: 'echo-1',
        channelKey: 'inbox:12',
        targetContactInboxId: 7,
        private: false,
      });

      const request = axiosMock.mock.calls[0][0];
      expect(request.method).toBe('post');
      expect(request.url).toBe(
        '/api/v1/accounts/43/contacts/5/dialog/messages'
      );
      expect(request.data).toMatchObject({
        content: 'Hello',
        echo_id: 'echo-1',
        channel_key: 'inbox:12',
        target_contact_inbox_id: 7,
      });
    });
  });
});
