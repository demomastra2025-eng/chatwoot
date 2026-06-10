import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';

const mockVoiceAPI = vi.hoisted(() => ({
  getReadiness: vi.fn(),
  getVirtualPbxReadiness: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: mockVoiceAPI,
}));

const { default: FonosterReadiness } = await import('./FonosterReadiness.vue');

const buildWrapper = inbox =>
  mount(FonosterReadiness, {
    props: { inbox },
    global: {
      mocks: {
        $t: key => key,
      },
    },
  });

describe('FonosterReadiness', () => {
  beforeEach(() => {
    mockVoiceAPI.getReadiness.mockReset();
    mockVoiceAPI.getVirtualPbxReadiness.mockReset();
    mockVoiceAPI.getReadiness.mockResolvedValue({
      payload: {
        bridge: { healthy: true },
        account: { ready_inboxes_count: 1, fonoster_inboxes_count: 1 },
        inboxes: [
          {
            id: 42,
            ready: true,
            last_synced_at: '2026-06-10T09:00:00Z',
            warnings: [],
          },
        ],
        warnings: [],
      },
    });
    mockVoiceAPI.getVirtualPbxReadiness.mockResolvedValue({
      payload: {
        operation: 'readiness_check',
        remote_commit: false,
        mutation_allowed: false,
        warnings: [
          {
            code: 'phone_split_configured',
            message: 'Display phone and ingress are intentionally split',
            severity: 'info',
          },
        ],
        config: {
          provider_template: { label: 'Sipuni' },
          phone_numbers: {
            display_phone_number: '+77123456789',
            ingress_number: '056124100014',
          },
          ownership: { read_only: false },
          resources: {
            number_ref: 'sipuni-internal-asterisk-056124100014',
            trunk_ref: 'trunk-sipuni-onelink-out',
            provider_connection: { name: 'Sipuni external line' },
          },
          profiles: [{ internal_extension: '207' }],
          warnings: [
            {
              code: 'phone_split_configured',
              message: 'Display phone and ingress are intentionally split',
              severity: 'info',
            },
          ],
        },
      },
    });
  });

  it('loads and renders Virtual PBX diagnostics for Fonoster voice inboxes', async () => {
    const wrapper = buildWrapper({
      id: 42,
      provider: 'fonoster',
      channel_type: 'Channel::Voice',
    });

    await flushPromises();

    expect(mockVoiceAPI.getReadiness).toHaveBeenCalledTimes(1);
    expect(mockVoiceAPI.getVirtualPbxReadiness).toHaveBeenCalledWith(42);
    expect(
      wrapper.find('[data-testid="virtual-pbx-diagnostics"]').exists()
    ).toBe(true);
    expect(wrapper.text()).toContain('Sipuni');
    expect(wrapper.text()).toContain('+77123456789 → 056124100014');
    expect(wrapper.text()).toContain('sipuni-internal-asterisk-056124100014');
    expect(wrapper.text()).toContain('trunk-sipuni-onelink-out');
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.REMOTE_MUTATIONS_BLOCKED'
    );
    expect(wrapper.text()).toContain(
      'Display phone and ingress are intentionally split'
    );
    expect(wrapper.text().match(/phone_split_configured/g)).toHaveLength(1);
  });

  it('does not call readiness APIs for non-Fonoster inboxes', async () => {
    buildWrapper({
      id: 99,
      provider: 'whatsapp',
      channel_type: 'Channel::Whatsapp',
    });

    await flushPromises();

    expect(mockVoiceAPI.getReadiness).not.toHaveBeenCalled();
    expect(mockVoiceAPI.getVirtualPbxReadiness).not.toHaveBeenCalled();
  });

  it('does not call readiness APIs before inbox id is available', async () => {
    buildWrapper({
      provider: 'fonoster',
      channel_type: 'Channel::Voice',
    });

    await flushPromises();

    expect(mockVoiceAPI.getReadiness).not.toHaveBeenCalled();
    expect(mockVoiceAPI.getVirtualPbxReadiness).not.toHaveBeenCalled();
  });

  it('keeps base readiness visible when Virtual PBX diagnostics fails', async () => {
    mockVoiceAPI.getVirtualPbxReadiness.mockRejectedValueOnce(
      new Error('Virtual PBX diagnostics unavailable')
    );

    const wrapper = buildWrapper({
      id: 42,
      provider: 'fonoster',
      channel_type: 'Channel::Voice',
    });

    await flushPromises();

    expect(mockVoiceAPI.getReadiness).toHaveBeenCalledTimes(1);
    expect(wrapper.text()).toContain('Virtual PBX diagnostics unavailable');
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.READY'
    );
    expect(
      wrapper.find('[data-testid="virtual-pbx-diagnostics"]').exists()
    ).toBe(false);
  });
});
