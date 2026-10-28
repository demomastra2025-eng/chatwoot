import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import ContactInfo from './ContactInfo.vue';
import SocialIcons from './SocialIcons.vue';
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

  it('keeps name and phone beside the avatar without inline pencil icon and omits MedElement or country subtitle', async () => {
    const wrapper = buildWrapper({
      contact: {
        phone_number: '+77000000001',
        additional_attributes: { country: 'Kazakhstan' },
      },
    });
    const header = wrapper.get('[data-test="contact-header"]');
    const heading = header.find('h3');
    expect(heading.classes()).toContain('line-clamp-2');
    expect(heading.find('.i-lucide-pencil').exists()).toBe(false);
    expect(header.findComponent({ name: 'ContactInfoRow' }).exists()).toBe(
      true
    );
    expect(header.find('[data-test="contact-header-meta"]').exists()).toBe(
      false
    );
    expect(
      wrapper.findComponent({ name: 'ContactChannelLabels' }).exists()
    ).toBe(false);

    await heading.trigger('click');
    expect(wrapper.vm.isEditingName).toBe(true);
  });

  it('shows 3 grey square NextButton profile actions without delete button even for admins', async () => {
    useAdminMock.mockReturnValue({ isAdmin: true });
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null);
    const wrapper = buildWrapper({
      showActions: true,
      canAddFamilyMember: true,
    });
    const actions = wrapper.get('[data-test="contact-panel-actions"]');
    const buttons = actions.findAllComponents({ name: 'NextButton' });
    expect(buttons).toHaveLength(3);
    expect(buttons.map(btn => btn.props('icon'))).toEqual([
      'i-ph-pencil-simple',
      'i-ph-arrows-merge',
      'i-lucide-external-link',
    ]);
    buttons.forEach(btn => {
      expect(btn.attributes('slate')).toBeDefined();
      expect(btn.attributes('faded')).toBeDefined();
      expect(btn.attributes('sm')).toBeDefined();
    });
    expect(actions.find('.i-lucide-trash-2').exists()).toBe(false);

    await buttons[2].vm.$emit('click');
    expect(openSpy).toHaveBeenCalledWith(
      '/app/accounts/1/contacts/154',
      '_blank',
      'noopener,noreferrer'
    );
    openSpy.mockRestore();
  });

  it('renders monochrome social profile chips with @handle text and without double @', () => {
    const wrapper = shallowMount(SocialIcons, {
      props: {
        socialProfiles: {
          telegram: 'asselya_k',
          instagram: '@clinic_kz',
        },
      },
      global: {
        mocks: {
          $t: key => key,
        },
        stubs: {
          'fluent-icon': true,
        },
      },
    });
    const tg = wrapper.get('[data-test="social-profile-telegram"]');
    const ig = wrapper.get('[data-test="social-profile-instagram"]');
    expect(tg.text()).toBe('@asselya_k');
    expect(tg.get('a').attributes('href')).toBe('https://t.me/asselya_k');
    expect(ig.text()).toBe('@clinic_kz');
    expect(ig.get('a').attributes('href')).toBe(
      'https://instagram.com/clinic_kz'
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
  it('renders client language with AI confidence badge and dispatches update on manual selection', async () => {
    const wrapper = buildWrapper({
      contact: {
        additional_attributes: {
          client_language: 'kk',
          client_language_source: 'ai',
          client_language_confidence: 96,
        },
      },
    });

    const row = wrapper.get('[data-test="contact-client-language-row"]');
    expect(row.text()).toContain('96%');

    const select = wrapper.get('[data-test="contact-client-language-select"]');
    expect(select.element.value).toBe('kk');

    await select.setValue('ru');
    expect(dispatchMock).toHaveBeenCalledWith(
      'contacts/update',
      expect.objectContaining({
        id: 154,
        client_language: 'ru',
        additional_attributes: expect.objectContaining({
          client_language: 'ru',
          client_language_source: 'manual',
          client_language_confidence: 100,
        }),
      })
    );
  });
});
