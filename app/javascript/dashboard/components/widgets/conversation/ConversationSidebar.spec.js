import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';
import { flushPromises, shallowMount } from '@vue/test-utils';

import ConversationSidebar from './ConversationSidebar.vue';

const mocks = vi.hoisted(() => ({
  currentAccount: null,
  uiSettings: null,
  width: null,
  updateUISettings: vi.fn(),
  isFeatureEnabledonAccount: { __v_isRef: true, value: () => true },
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: name => {
    const getters = {
      'accounts/isFeatureEnabledonAccount': mocks.isFeatureEnabledonAccount,
      getCurrentAccountId: { __v_isRef: true, value: 1 },
      getCurrentUser: {
        __v_isRef: true,
        value: {
          accounts: [
            {
              id: 1,
              permissions: ['administrator', 'crm_manage', 'scheduling_manage'],
            },
          ],
        },
      },
    };
    return getters[name];
  },
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: mocks.uiSettings,
    updateUISettings: mocks.updateUISettings,
  }),
}));

vi.mock('@vueuse/core', () => ({
  useWindowSize: () => ({ width: mocks.width }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountId: { value: 1 },
    currentAccount: mocks.currentAccount,
  }),
}));

const mountComponent = (currentChat = { id: 1, inbox_id: 2 }) =>
  shallowMount(ConversationSidebar, {
    props: {
      currentChat,
    },
    global: {
      stubs: {
        ContactPanel: {
          name: 'ContactPanel',
          props: ['conversationId', 'inboxId'],
          template: '<div />',
        },
        CrmConversationDealsSidebar: {
          name: 'CrmConversationDealsSidebar',
          template: '<div />',
        },
        SchedulingConversationAppointmentsSidebar: {
          name: 'SchedulingConversationAppointmentsSidebar',
          template: '<div />',
        },
        ScheduledMessagesPanel: {
          name: 'ScheduledMessagesPanel',
          props: ['conversationId', 'remindableType', 'remindableId'],
          template: '<div />',
        },
      },
    },
  });

describe('ConversationSidebar', () => {
  beforeEach(() => {
    mocks.currentAccount = ref({ settings: {} });
    mocks.isFeatureEnabledonAccount.value = () => true;
    mocks.width = ref(390);
    mocks.updateUISettings.mockClear();
  });

  it('moves the mobile drawer off-canvas when no sidebar tab is open', () => {
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
      is_touch_sidebar_open: false,
    });

    const wrapper = mountComponent();

    expect(wrapper.classes()).toContain('ltr:translate-x-full');
    expect(wrapper.classes()).toContain('rtl:-translate-x-full');
    expect(wrapper.classes()).toContain('pointer-events-none');
  });

  it('keeps the mobile drawer visible when contact sidebar is open', () => {
    mocks.uiSettings = ref({
      is_contact_sidebar_open: true,
      is_touch_sidebar_open: false,
    });

    const wrapper = mountComponent();

    expect(wrapper.classes()).toContain('translate-x-0');
    expect(wrapper.classes()).not.toContain('pointer-events-none');
  });

  it('uses contact-sized width for the deal sidebar', () => {
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
      is_crm_deal_panel_open: true,
      is_touch_sidebar_open: false,
    });

    const wrapper = mountComponent();

    expect(wrapper.classes()).toEqual(
      expect.arrayContaining([
        'max-w-sm',
        'md:w-[320px]',
        'md:min-w-[320px]',
        '2xl:w-[360px]',
        '2xl:min-w-[360px]',
      ])
    );
    expect(wrapper.classes()).not.toContain('md:w-[28rem]');
    expect(wrapper.classes()).not.toContain('xl:w-[30rem]');
  });

  it('renders the deals panel independently from navigation visibility', () => {
    mocks.currentAccount.value = {
      settings: {
        dashboard_sidebar_hidden_items: [
          'Conversation:Pipelines',
          'Conversation:AppointmentStatuses',
        ],
        dashboard_sidebar_hidden_items_version: 13,
      },
    };
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
      is_crm_deal_panel_open: true,
      is_scheduling_appointments_panel_open: false,
      is_touch_sidebar_open: false,
    });

    const wrapper = mountComponent();

    expect(
      wrapper.findComponent({ name: 'CrmConversationDealsSidebar' }).exists()
    ).toBe(true);
  });

  it('renders the appointments panel independently from navigation visibility', () => {
    mocks.currentAccount.value = {
      settings: {
        dashboard_sidebar_hidden_items: [
          'Conversation:Pipelines',
          'Conversation:AppointmentStatuses',
        ],
        dashboard_sidebar_hidden_items_version: 13,
      },
    };
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
      is_crm_deal_panel_open: false,
      is_scheduling_appointments_panel_open: true,
      is_touch_sidebar_open: false,
    });

    const wrapper = mountComponent();

    expect(
      wrapper
        .findComponent({ name: 'SchedulingConversationAppointmentsSidebar' })
        .exists()
    ).toBe(true);
  });

  it('uses the active reply conversation for communication thread contact sidebar', async () => {
    mocks.uiSettings = ref({
      is_contact_sidebar_open: true,
      is_touch_sidebar_open: false,
    });

    const wrapper = mountComponent({
      id: 10,
      inbox_id: 2,
      is_communication_thread: true,
      active_reply_channel: {
        conversation_id: 101,
        inbox_id: 202,
      },
    });
    await flushPromises();

    const contactPanel = wrapper.findComponent({ name: 'ContactPanel' });
    expect(contactPanel.props('conversationId')).toBe(101);
    expect(contactPanel.props('inboxId')).toBe(202);
  });

  it('renders communication thread scheduled messages with the active reply and thread reminder context', async () => {
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
      is_touch_sidebar_open: true,
    });

    const wrapper = mountComponent({
      id: 10,
      inbox_id: 2,
      is_communication_thread: true,
      active_reply_channel: {
        conversation_id: 101,
        inbox_id: 202,
      },
    });
    await flushPromises();

    const scheduledMessages = wrapper.findComponent({
      name: 'ScheduledMessagesPanel',
    });
    expect(scheduledMessages.props('conversationId')).toBe(101);
    expect(scheduledMessages.props('remindableType')).toBe(
      'CommunicationThread'
    );
    expect(scheduledMessages.props('remindableId')).toBe(10);
  });

  it('renders regular conversation scheduled messages with conversation reminder context', async () => {
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
      is_touch_sidebar_open: true,
    });

    const wrapper = mountComponent({ id: 12, inbox_id: 2 });
    await flushPromises();

    const scheduledMessages = wrapper.findComponent({
      name: 'ScheduledMessagesPanel',
    });
    expect(scheduledMessages.props('conversationId')).toBe(12);
    expect(scheduledMessages.props('remindableType')).toBe('Conversation');
    expect(scheduledMessages.props('remindableId')).toBe(12);
  });
});
