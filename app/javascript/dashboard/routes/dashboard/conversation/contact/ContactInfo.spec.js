import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import ContactInfo from './ContactInfo.vue';

const routerPushMock = vi.fn();
const dispatchMock = vi.fn();
const updateUISettingsMock = vi.fn();
const useAdminMock = vi.fn();
const useUISettingsMock = vi.fn();
const openWithChannelMock = vi.fn();

vi.mock('dashboard/composables/useAdmin', () => ({
  useAdmin: (...args) => useAdminMock(...args),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: (...args) => useUISettingsMock(...args),
}));

vi.mock('dashboard/components-next/Contacts/VoiceCallButton.vue', () => ({
  default: {
    name: 'VoiceCallButton',
    template: '<div />',
  },
}));

const createStore = conversations => ({
  getters: {
    getCurrentAccountId: 1,
    getCurrentUser: {
      accounts: [{ id: 1, permissions: [] }],
    },
    'accounts/isFeatureEnabledonAccount': () => false,
    'contacts/getUIFlags': {},
    'agents/getVerifiedAgents': [
      { id: 7, name: 'Aigerim Agent' },
      { id: 9, name: 'Bob Agent' },
    ],
    'contactConversations/getAllConversationsByContactId': () => conversations,
  },
  state: {
    contactConversations: {
      records: {
        154: true,
      },
    },
  },
  dispatch: dispatchMock,
});

const buildWrapper = ({ conversations = [], contact = {} } = {}) =>
  shallowMount(ContactInfo, {
    props: {
      contact: {
        id: 154,
        name: 'Jane Doe',
        additional_attributes: {},
        ...contact,
      },
    },
    global: {
      mocks: {
        $route: {
          name: 'inbox_view_conversation',
          params: {
            accountId: '1',
            id: '138',
          },
        },
        $router: {
          push: routerPushMock,
        },
        $store: createStore(conversations),
        $t: key => key,
      },
      stubs: {
        Avatar: true,
        ComposeConversation: {
          name: 'ComposeConversation',
          template: '<div />',
          methods: { openWithChannel: openWithChannelMock },
        },
        ContactChannelLabels: true,
        ContactInfoRow: true,
        ContactMergeModal: true,
        ComboBox: true,
        EditContact: true,
        NextButton: true,
        SocialIcons: true,
        VoiceCallButton: true,
        'woot-delete-modal': true,
      },
    },
  });

describe('ContactInfo', () => {
  beforeEach(() => {
    dispatchMock.mockReset();
    routerPushMock.mockReset();
    openWithChannelMock.mockReset();
    updateUISettingsMock.mockReset();

    useAdminMock.mockReturnValue({
      isAdmin: false,
    });
    useUISettingsMock.mockReturnValue({
      updateUISettings: updateUISettingsMock,
    });

    window.history.replaceState({}, '', '/');
  });

  it('delegates channel shortcuts to the authoritative compose flow', async () => {
    const wrapper = buildWrapper();

    await wrapper.vm.openChannelConversation({
      inboxId: 7,
    });

    expect(openWithChannelMock).toHaveBeenCalledWith({
      contact: expect.objectContaining({ id: 154 }),
      channelIdentity: { inboxId: 7 },
    });
    expect(routerPushMock).not.toHaveBeenCalled();
  });

  it('marks only non-resolved inbox conversations as active', () => {
    const wrapper = buildWrapper({
      conversations: [
        { id: 42, inboxId: 7, status: 'resolved' },
        { id: 43, inboxId: 8, status: 'open' },
      ],
    });

    expect(wrapper.vm.existingConversationInboxIds).toEqual([8]);
  });

  it('closes the edit contact modal when the modal show model is set to false', async () => {
    const wrapper = buildWrapper();

    await wrapper.setData({ showEditModal: true });
    wrapper
      .findComponent({ name: 'EditContact' })
      .vm.$emit('update:show', false);

    expect(wrapper.vm.showEditModal).toBe(false);
  });

  it('prefills a calendar appointment by opaque record ids only', () => {
    const wrapper = buildWrapper({
      contact: {
        name: 'Айжан',
        last_name: 'Касымова',
        middle_name: 'Ерлановна',
        phone_number: ['+7', '700', '000', '0001'].join(''),
      },
    });

    wrapper.vm.onCreateAppointment();

    expect(routerPushMock).toHaveBeenCalledWith({
      name: 'scheduling_calendar',
      params: { accountId: 1 },
      query: {
        action: 'new',
        contactId: wrapper.vm.contact.id,
        conversationId: Number(wrapper.vm.$route.params.id),
        source: 'contact',
      },
    });
  });

  it('updates the shared contact owner from the owner combobox', async () => {
    const wrapper = buildWrapper({
      contact: {
        owner_id: 7,
        owner: { id: 7, name: 'Aigerim Agent' },
      },
    });

    const ownerSelector = wrapper.findComponent({ name: 'ComboBox' });
    expect(ownerSelector.props('modelValue')).toBe(7);
    expect(ownerSelector.props('options')).toEqual([
      { value: '', label: 'CONTACT_PANEL.OWNER_UNASSIGNED' },
      { value: 7, label: 'Aigerim Agent' },
      { value: 9, label: 'Bob Agent' },
    ]);

    await ownerSelector.vm.$emit('update:modelValue', 9);

    expect(dispatchMock).toHaveBeenCalledWith('contacts/update', {
      id: 154,
      owner_id: 9,
    });
  });
});
