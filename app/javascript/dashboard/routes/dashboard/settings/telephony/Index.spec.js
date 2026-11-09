import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import { describe, expect, it, vi, beforeEach } from 'vitest';

import TelephonySettings from './Index.vue';

const alertMock = vi.hoisted(() => vi.fn());
const getVirtualPbxStatusMock = vi.hoisted(() => vi.fn());
const updateVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const provisionVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const getInboxMembersMock = vi.hoisted(() => vi.fn());
const storeDispatchMock = vi.hoisted(() => vi.fn());

const inboxesRef = ref([]);
const agentsRef = ref([
  { id: 7, name: 'Ada Agent' },
  { id: 8, name: 'Grace Agent' },
]);

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: alertMock,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({
    dispatch: storeDispatchMock,
  }),
  useMapGetter: key => {
    if (key === 'inboxes/getInboxes') return inboxesRef;
    if (key === 'agents/getAgents') return agentsRef;
    return ref([]);
  },
}));

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    getVirtualPbxStatus: getVirtualPbxStatusMock,
    updateVirtualPbxChannel: updateVirtualPbxChannelMock,
    provisionVirtualPbxChannel: provisionVirtualPbxChannelMock,
  },
}));

vi.mock('dashboard/api/inboxMembers', () => ({
  default: {
    get: getInboxMembersMock,
  },
}));

const mountPage = () =>
  mount(TelephonySettings, {
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        SettingsLayout: {
          template: '<div><slot name="header" /><slot name="body" /></div>',
        },
        BaseSettingsHeader: {
          props: ['title', 'description'],
          template:
            '<header :data-title="title" :data-description="description" />',
        },
        Button: {
          props: ['label', 'type', 'disabled'],
          template:
            '<button :type="type || `button`" :disabled="disabled">{{ label }}</button>',
        },
      },
    },
  });

describe('TelephonySettings', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    storeDispatchMock.mockResolvedValue({});
    getInboxMembersMock.mockResolvedValue({ data: { payload: [] } });
    inboxesRef.value = [];
  });

  it('shows empty state when no voice channels are connected', async () => {
    const wrapper = mountPage();
    await flushPromises();

    expect(wrapper.find('[data-testid="telephony-empty-state"]').exists()).toBe(
      true
    );
  });

  it('applies unified call routing across all connected phone types (Virtual PBX and WhatsApp Calling)', async () => {
    inboxesRef.value = [
      {
        id: 42,
        name: 'Sipuni Main',
        channel_type: 'Channel::Voice',
        provider: 'sipuni',
        phone_number: '+77001112233',
      },
      {
        id: 43,
        name: 'Altel Wazo',
        channel_type: 'Channel::Voice',
        provider: 'wazo',
        phone_number: '+77085012233',
      },
      {
        id: 55,
        name: 'WhatsApp Cloud Calls',
        channel_type: 'Channel::Whatsapp',
        provider: 'whatsapp_cloud',
        phone_number: '+77019998877',
        provider_config: {
          calling_enabled: true,
        },
      },
    ];

    getVirtualPbxStatusMock.mockImplementation(inboxId =>
      Promise.resolve({
        payload: {
          ui_config: {
            inbox_id: inboxId,
            configuration_version: inboxId === 42 ? 5 : 2,
            channel: {
              provider_kind: inboxId === 42 ? 'sipuni' : 'wazo',
              display_phone_number:
                inboxId === 42 ? '+77001112233' : '+77085012233',
            },
            routing: {
              mode: 'operator',
              fallback_mode: 'reject',
              operator_distribution_mode: 'broadcast',
              max_call_duration_seconds: 1800,
            },
            employees: [],
            permissions: {
              editable: true,
              remote_commit_allowed: inboxId === 43,
            },
          },
        },
      })
    );

    updateVirtualPbxChannelMock.mockResolvedValue({ payload: { errors: [] } });
    provisionVirtualPbxChannelMock.mockResolvedValue({ payload: {} });

    const wrapper = mountPage();
    await flushPromises();

    const phonePills = wrapper.findAll(
      '[data-testid="telephony-routing-phone-pill"]'
    );
    expect(phonePills).toHaveLength(3);

    await wrapper
      .find('[data-testid="telephony-routing-group-name"]')
      .setValue('Отдел продаж');
    await wrapper
      .find('[data-testid="telephony-routing-group-strategy"]')
      .setValue('round_robin');
    const operatorBtns = wrapper.findAll(
      '[data-testid="telephony-routing-group-operator"]'
    );
    await operatorBtns[0].trigger('click');

    await wrapper
      .find('[data-testid="telephony-save-routing"]')
      .trigger('click');
    await flushPromises();

    expect(updateVirtualPbxChannelMock).toHaveBeenCalledWith(
      42,
      expect.objectContaining({
        expected_configuration_version: 5,
        routing: expect.objectContaining({
          operator_distribution_mode: 'targeted',
          call_routing: expect.objectContaining({
            inbound: expect.objectContaining({
              groups: [
                expect.objectContaining({
                  name: 'Отдел продаж',
                  strategy: 'round_robin',
                  user_ids: [7],
                }),
              ],
            }),
          }),
        }),
      }),
      { dryRun: false, remoteCommit: false }
    );

    expect(updateVirtualPbxChannelMock).toHaveBeenCalledWith(
      43,
      expect.objectContaining({
        expected_configuration_version: 2,
        routing: expect.objectContaining({
          operator_distribution_mode: 'targeted',
          call_routing: expect.objectContaining({
            inbound: expect.objectContaining({
              routing_authority: 'onelink',
            }),
          }),
        }),
      }),
      { dryRun: false, remoteCommit: false }
    );

    expect(storeDispatchMock).toHaveBeenCalledWith(
      'inboxes/updateInbox',
      expect.objectContaining({
        id: 55,
        formData: false,
        channel: expect.objectContaining({
          provider_config: expect.objectContaining({
            calling_enabled: true,
            call_routing: expect.objectContaining({
              inbound: expect.objectContaining({
                groups: [
                  expect.objectContaining({
                    name: 'Отдел продаж',
                    strategy: 'round_robin',
                    user_ids: [7],
                  }),
                ],
              }),
            }),
          }),
        }),
      })
    );
  });

  it('consolidates all connected voice phones and saves employee line assignments', async () => {
    inboxesRef.value = [
      {
        id: 42,
        name: 'Sipuni Main',
        channel_type: 'Channel::Voice',
        provider: 'sipuni',
        phone_number: '+77001112233',
      },
      {
        id: 43,
        name: 'Altel Wazo',
        channel_type: 'Channel::Voice',
        provider: 'wazo',
        phone_number: '+77085012233',
      },
    ];

    getVirtualPbxStatusMock.mockImplementation(inboxId => {
      if (inboxId === 42) {
        return Promise.resolve({
          payload: {
            ui_config: {
              inbox_id: 42,
              configuration_version: 5,
              channel: {
                provider_kind: 'sipuni',
                provider_label: 'Sipuni',
                display_phone_number: '+77001112233',
              },
              employees: [
                {
                  id: 301,
                  user_id: 7,
                  user_name: 'Ada Agent',
                  internal_extension: '100',
                  sip_username: 'agent-100',
                  sip_password_configured: true,
                  enabled: true,
                },
              ],
              permissions: {
                editable: true,
                remote_commit_allowed: false,
              },
            },
          },
        });
      }
      return Promise.resolve({
        payload: {
          ui_config: {
            inbox_id: 43,
            configuration_version: 2,
            channel: {
              provider_kind: 'wazo',
              provider_label: 'Wazo',
              display_phone_number: '+77085012233',
            },
            employees: [],
            permissions: {
              editable: true,
              remote_commit_allowed: true,
            },
          },
        },
      });
    });

    updateVirtualPbxChannelMock.mockResolvedValue({ payload: { errors: [] } });
    provisionVirtualPbxChannelMock.mockResolvedValue({ payload: {} });

    const wrapper = mountPage();
    await flushPromises();

    await wrapper.find('[data-testid="telephony-tab-lines"]').trigger('click');

    const cards = wrapper.findAll('[data-testid="telephony-phone-card"]');
    expect(cards).toHaveLength(2);
    expect(cards[0].text()).toContain('Sipuni Main');
    expect(cards[0].text()).toContain('+77001112233');
    expect(cards[1].text()).toContain('Altel Wazo');
    expect(cards[1].text()).toContain('+77085012233');

    await cards[1]
      .find('[data-testid="telephony-add-profile"]')
      .trigger('click');
    await cards[1]
      .find('[data-testid="telephony-profile-employee"]')
      .setValue('8');
    await cards[1]
      .find('[data-testid="telephony-profile-extension"]')
      .setValue('102');
    await cards[1].find('form').trigger('submit');
    await flushPromises();

    expect(updateVirtualPbxChannelMock).toHaveBeenCalledWith(
      43,
      {
        expected_configuration_version: 2,
        profiles: [
          {
            profile_kind: 'human_operator',
            user_id: 8,
            internal_extension: '102',
            enabled: true,
          },
        ],
      },
      { dryRun: false, remoteCommit: false }
    );
    expect(provisionVirtualPbxChannelMock).toHaveBeenCalledWith(43, {
      remoteCommit: true,
      includeDiagnostics: false,
    });
  });
});
