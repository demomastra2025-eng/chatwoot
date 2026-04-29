import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import ContactInfo from './ContactInfo.vue';

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

const createStore = conversations => ({
  getters: {
    getCurrentAccountId: 1,
    getCurrentUser: {
      accounts: [{ id: 1, permissions: [] }],
    },
    'accounts/isFeatureEnabledonAccount': () => false,
    'contacts/getUIFlags': {},
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

const buildWrapper = ({ conversations = [] } = {}) =>
  shallowMount(ContactInfo, {
    props: {
      contact: {
        id: 154,
        name: 'Jane Doe',
        additional_attributes: {},
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
        ComposeConversation: true,
        ContactChannelLabels: true,
        ContactInfoRow: true,
        ContactMergeModal: true,
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

  it('opens an existing channel conversation in the standard inbox route', () => {
    window.history.replaceState(
      {},
      '',
      '/app/accounts/1/inbox-view/conversation/138?status=pending'
    );

    const wrapper = buildWrapper({
      conversations: [
        {
          id: 42,
          inboxId: 7,
        },
      ],
    });

    wrapper.vm.openChannelConversation({
      inboxId: 7,
    });

    expect(routerPushMock).toHaveBeenCalledWith(
      '/app/accounts/1/inbox/7/conversations/42?status=pending'
    );
  });

  it('closes the edit contact modal when the modal show model is set to false', async () => {
    const wrapper = buildWrapper();

    await wrapper.setData({ showEditModal: true });
    wrapper
      .findComponent({ name: 'EditContact' })
      .vm.$emit('update:show', false);

    expect(wrapper.vm.showEditModal).toBe(false);
  });
});
