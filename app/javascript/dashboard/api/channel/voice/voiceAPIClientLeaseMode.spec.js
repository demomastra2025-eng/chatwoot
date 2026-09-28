import voiceAPIClient from './voiceAPIClient';

const tabLeadership = vi.hoisted(() => ({ owner: true }));

vi.mock('./webphoneTabLeadership', () => ({
  isWebphoneTabOwner: () => tabLeadership.owner,
  webphoneBrowserInstanceId: () => 'browser-instance-1',
}));

describe('#VoiceAPI webphone registration lease mode', () => {
  const originalAxios = window.axios;
  const originalPathname = window.location.pathname;
  const axiosMock = {
    post: vi.fn(() => Promise.resolve({ data: { payload: {} } })),
  };
  const tokenPath = '/api/v1/accounts/530/telephony/webphone/token';

  beforeEach(() => {
    window.axios = axiosMock;
    window.history.pushState({}, '', '/app/accounts/530/dashboard');
    axiosMock.post.mockClear();
    tabLeadership.owner = true;
  });

  afterEach(() => {
    window.axios = originalAxios;
    window.history.pushState({}, '', originalPathname);
  });

  it('presents the browser identity only from the owner tab', async () => {
    await voiceAPIClient.getNativeWebphoneToken(42);

    const [path, body] = axiosMock.post.mock.calls[0];
    expect(path).toBe(tokenPath);
    expect(body).toEqual({
      client_instance_id: expect.any(String),
      browser_instance_id: 'browser-instance-1',
      inbox_id: 42,
    });
  });

  it('asks in observe mode from a follower tab so it never takes the lease', async () => {
    tabLeadership.owner = false;

    await voiceAPIClient.getNativeWebphoneToken(42);
    await voiceAPIClient.getWebphoneToken();

    axiosMock.post.mock.calls.forEach(([path, body]) => {
      expect(path).toBe(tokenPath);
      expect(body).toMatchObject({
        client_instance_id: expect.any(String),
        lease_mode: 'observe',
      });
      expect(body).not.toHaveProperty('browser_instance_id');
    });
    expect(axiosMock.post).toHaveBeenCalledTimes(2);
  });

  it('switches back to a leasing request once the tab owns the phone', async () => {
    tabLeadership.owner = false;
    await voiceAPIClient.getNativeWebphoneToken();
    tabLeadership.owner = true;
    await voiceAPIClient.getNativeWebphoneToken();

    const [, followerBody] = axiosMock.post.mock.calls[0];
    const [, ownerBody] = axiosMock.post.mock.calls[1];
    expect(followerBody.lease_mode).toBe('observe');
    expect(ownerBody).not.toHaveProperty('lease_mode');
    expect(ownerBody.client_instance_id).toBe(followerBody.client_instance_id);
    expect(ownerBody.browser_instance_id).toBe('browser-instance-1');
  });
});
