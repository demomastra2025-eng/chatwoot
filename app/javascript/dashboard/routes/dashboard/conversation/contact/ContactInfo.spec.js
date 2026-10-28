import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import ContactInfo from './ContactInfo.vue';
import {
  CRM_DEAL_MANAGE_PERMISSIONS,
  CRM_TASK_MANAGE_PERMISSIONS,
} from 'dashboard/constants/permissions';

const routerPushMock = vi.fn();
const dispatchMock = vi.fn();
const updateUISettingsMock = vi.fn();
const useAdminMock = vi.fn();
const useUISettingsMock = vi.fn();

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

const createStore = (conversations, showActions = false) => ({
  getters: {
    getCurrentAccountId: 1,
    getCurrentUser: {
      accounts: [
        {
          id: 1,
          permissions: showActions
            ? [...CRM_DEAL_MANAGE_PERMISSIONS, ...CRM_TASK_MANAGE_PERMISSIONS]
            : [],
        },
      ],
    },
    'accounts/isFeatureEnabledonAccount': () => showActions,
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

const buildWrapper = ({
  conversations = [],
  contact = {},
  showActions = false,
  canAddFamilyMember = false,
} = {}) =>
  shallowMount(ContactInfo, {
    props: {
      canAddFamilyMember,
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
        $store: createStore(conversations, showActions),
        $t: key => key,
      },
      stubs: {
        Avatar: true,
        ContactChannelLabels: true,
        ContactInfoRow: true,
        ContactMergeModal: true,
        CrmConversationDealsSidebar: true,
        CrmContactTaskDrawer: true,
        SchedulingConversationAppointmentsSidebar: true,
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
    updateUISettingsMock.mockReset();

    useAdminMock.mockReturnValue({
      isAdmin: false,
    });
    useUISettingsMock.mockReturnValue({
      updateUISettings: updateUISettingsMock,
    });

    window.history.replaceState({}, '', '/');
  });

  it('keeps name, phone and one metadata line beside the avatar', () => {
    const wrapper = buildWrapper({
      contact: {
        phone_number: '+77000000001',
        additional_attributes: { country: 'Казахстан' },
      },
    });
    const header = wrapper.get('[data-test="contact-header"]');
    expect(header.find('h3').classes()).toContain('line-clamp-2');
    expect(header.findComponent({ name: 'ContactInfoRow' }).exists()).toBe(
      true
    );
    expect(header.get('[data-test="contact-header-meta"]').text()).toBe(
      'Казахстан'
    );
  });

  it('shows compact profile actions without creation buttons or family action', () => {
    const wrapper = buildWrapper({
      showActions: true,
      canAddFamilyMember: true,
    });
    const actions = wrapper.get('[data-test="contact-panel-actions"]');
    expect(actions.findAll('button')).toHaveLength(2);
    expect(actions.findAll('a')).toHaveLength(1);
    expect(actions.text()).not.toContain(
      'SCHEDULING.PATIENT_CONTEXT.ADD_FAMILY_MEMBER'
    );
    expect(
      wrapper.findComponent({ name: 'CrmContactTaskDrawer' }).exists()
    ).toBe(false);
  });

  it('has no button that opens a message to the person whose dialog is already open', () => {
    const wrapper = buildWrapper();

    expect(
      wrapper.findComponent({ name: 'ComposeConversation' }).exists()
    ).toBe(false);
    expect(wrapper.vm.openChannelConversation).toBeUndefined();
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

  it('keeps the contact owner in the edit modal instead of the panel', async () => {
    const wrapper = buildWrapper({
      contact: {
        owner_id: 7,
        owner: { id: 7, name: 'Aigerim Agent' },
      },
    });

    expect(wrapper.findComponent({ name: 'ComboBox' }).exists()).toBe(false);
    wrapper.vm.openEditModal();
    await wrapper.vm.$nextTick();
    expect(
      wrapper.findComponent({ name: 'EditContact' }).props('contact').owner_id
    ).toBe(7);
  });

  it('does not request contactable inboxes or conversations when contact id is missing', () => {
    buildWrapper({ contact: { id: undefined } });

    expect(dispatchMock).not.toHaveBeenCalledWith(
      'contacts/fetchContactableInbox',
      undefined
    );
    expect(dispatchMock).not.toHaveBeenCalledWith(
      'contactConversations/get',
      undefined
    );
  });
});
