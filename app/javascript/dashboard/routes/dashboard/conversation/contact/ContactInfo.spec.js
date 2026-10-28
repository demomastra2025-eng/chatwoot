import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import ContactInfo from './ContactInfo.vue';
import CrmTasksAPI from 'dashboard/api/crm/tasks';
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
vi.mock('dashboard/api/crm/tasks', () => ({
  default: { create: vi.fn() },
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
} = {}) =>
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
        $store: createStore(conversations, showActions),
        $t: key => key,
      },
      stubs: {
        Avatar: true,
        ContactChannelLabels: true,
        ContactInfoRow: true,
        ContactMergeModal: true,
        CrmConversationDealsSidebar: true,
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

  it('stacks icons over all four action labels in equal columns', () => {
    const wrapper = buildWrapper({ showActions: true });
    const actions = wrapper.get('[data-test="contact-panel-actions"]');
    expect(actions.classes()).toContain('grid-cols-4');
    const buttons = actions.findAll('next-button-stub');
    expect(buttons.map(button => button.attributes('label'))).toEqual([
      'CONTACT_PANEL.ACTION_DEAL',
      'CONTACT_PANEL.ACTION_TASK',
      'CONTACT_PANEL.ACTION_APPOINTMENT',
      'CONTACT_PANEL.ACTION_MORE',
    ]);
    buttons.forEach(button =>
      expect(button.classes()).toContain('contact-panel-action')
    );
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

  it('opens the appointment panel without leaving the dialog', () => {
    const wrapper = buildWrapper({
      contact: {
        name: 'Айжан',
        last_name: 'Касымова',
        middle_name: 'Ерлановна',
        phone_number: ['+7', '700', '000', '0001'].join(''),
      },
    });

    wrapper.vm.onCreateAppointment();

    expect(wrapper.vm.appointmentOpen).toBe(true);
    expect(routerPushMock).not.toHaveBeenCalled();
  });

  it('opens the existing deal form over the dialog', async () => {
    const wrapper = buildWrapper();
    wrapper.vm.onCreateDeal();
    await wrapper.vm.$nextTick();
    expect(wrapper.vm.dealOpen).toBe(true);
    expect(routerPushMock).not.toHaveBeenCalled();
  });

  it('creates a task from a popup without navigating away', async () => {
    CrmTasksAPI.create.mockResolvedValue({ data: { payload: { id: 16 } } });
    const wrapper = buildWrapper();
    wrapper.vm.onCreateTask();
    await wrapper.setData({ taskTitle: 'Позвонить пациенту' });
    await wrapper.vm.saveTask();
    expect(CrmTasksAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        title: 'Позвонить пациенту',
        activity_type: 'task',
      })
    );
    expect(routerPushMock).not.toHaveBeenCalled();
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
