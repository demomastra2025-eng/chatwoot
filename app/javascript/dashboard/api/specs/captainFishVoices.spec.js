import fishVoicesAPI from '../captain/fishVoices';

describe('#CaptainFishVoicesAPI', () => {
  const originalAxios = window.axios;
  const originalPathname = window.location.pathname;
  const axiosMock = {
    get: vi.fn(() => Promise.resolve({ data: { payload: [] } })),
    post: vi.fn(() => Promise.resolve({ data: { payload: {} } })),
    delete: vi.fn(() => Promise.resolve()),
  };

  beforeEach(() => {
    window.axios = axiosMock;
    window.history.pushState({}, '', '/app/accounts/530/captain/assistants/42');
    vi.clearAllMocks();
  });

  afterEach(() => {
    window.axios = originalAxios;
    window.history.pushState({}, '', originalPathname);
  });

  it('uses account-scoped lifecycle endpoints', async () => {
    await fishVoicesAPI.get();
    await fishVoicesAPI.refresh(17);
    await fishVoicesAPI.delete(17);

    expect(axiosMock.get).toHaveBeenNthCalledWith(
      1,
      '/api/v1/accounts/530/captain/fish_voices'
    );
    expect(axiosMock.get).toHaveBeenNthCalledWith(
      2,
      '/api/v1/accounts/530/captain/fish_voices/17'
    );
    expect(axiosMock.delete).toHaveBeenCalledWith(
      '/api/v1/accounts/530/captain/fish_voices/17'
    );
  });

  it('sends clone audio and consent as multipart form data', async () => {
    const voice = new File(['voice'], 'voice.mp3', { type: 'audio/mpeg' });

    await fishVoicesAPI.createVoice({
      title: 'Sales voice',
      voice,
      transcript: 'Hello',
      consentConfirmed: true,
    });

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/530/captain/fish_voices',
      expect.any(FormData),
      { headers: { 'Content-Type': 'multipart/form-data' } }
    );
    const formData = axiosMock.post.mock.calls[0][1];
    expect(formData.get('title')).toBe('Sales voice');
    expect(formData.get('voice')).toBe(voice);
    expect(formData.get('transcript')).toBe('Hello');
    expect(formData.get('consent_confirmed')).toBe('true');
  });
});
