import voiceAPIClient from './voiceAPIClient';

describe('#VoiceAPI virtual PBX remote commit defaults', () => {
  const originalAxios = window.axios;
  const originalPathname = window.location.pathname;
  const axiosMock = {
    post: vi.fn(() => Promise.resolve({ data: { payload: {} } })),
    patch: vi.fn(() => Promise.resolve({ data: { payload: {} } })),
    delete: vi.fn(() => Promise.resolve({ data: { payload: {} } })),
  };

  beforeEach(() => {
    window.axios = axiosMock;
    window.history.pushState({}, '', '/app/accounts/530/settings/inboxes/42');
    axiosMock.post.mockClear();
    axiosMock.patch.mockClear();
    axiosMock.delete.mockClear();
  });

  afterEach(() => {
    window.axios = originalAxios;
    window.history.pushState({}, '', originalPathname);
  });

  it('does not request remote provisioning by default', async () => {
    await voiceAPIClient.provisionVirtualPbxChannel(42);

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/530/telephony/virtual_pbx_channels/42/provision',
      { remote_commit: false, include_diagnostics: false }
    );
  });

  it('does not request remote create/update/delete mutations by default', async () => {
    await voiceAPIClient.createVirtualPbxChannel({ channel_name: 'PBX' });
    await voiceAPIClient.updateVirtualPbxChannel(42, { channel_name: 'PBX' });
    await voiceAPIClient.deleteVirtualPbxChannel(42, {
      confirm: true,
      dryRun: false,
    });

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/530/telephony/virtual_pbx_channels',
      {
        virtual_pbx_channel: { channel_name: 'PBX' },
        dry_run: false,
        remote_commit: false,
      }
    );
    expect(axiosMock.patch).toHaveBeenCalledWith(
      '/api/v1/accounts/530/telephony/virtual_pbx_channels/42',
      {
        virtual_pbx_channel: { channel_name: 'PBX' },
        dry_run: false,
        remote_commit: false,
      }
    );
    expect(axiosMock.delete).toHaveBeenCalledWith(
      '/api/v1/accounts/530/telephony/virtual_pbx_channels/42',
      {
        params: {
          confirm: true,
          dry_run: false,
          remote_commit: false,
        },
      }
    );
  });

  it('uploads browser webphone recordings under the account-scoped telephony call', async () => {
    const blob = new Blob(['recorded-audio'], { type: 'audio/webm' });

    await voiceAPIClient.uploadWebphoneRecording(
      'asterisk_analog:local:call-1',
      blob,
      {
        provider: 'asterisk_analog',
        direction: 'outbound',
        duration_ms: 1200,
      }
    );

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/530/telephony/calls/asterisk_analog%3Alocal%3Acall-1/upload_recording',
      expect.any(FormData),
      { headers: { 'Content-Type': 'multipart/form-data' } }
    );
    const formData = axiosMock.post.mock.calls.at(-1)[1];
    expect(formData.get('recording')).toBeInstanceOf(File);
    expect(formData.get('provider')).toBe('asterisk_analog');
    expect(formData.get('direction')).toBe('outbound');
    expect(formData.get('duration_ms')).toBe('1200');
  });
});
