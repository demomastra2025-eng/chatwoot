import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const routerPush = vi.hoisted(() => vi.fn());
const getContactableInboxes = vi.hoisted(() => vi.fn());
const storeDispatch = vi.hoisted(() => vi.fn());

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: routerPush }),
}));

vi.mock('dashboard/api/contacts', () => ({
  default: { getContactableInboxes },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('@vueuse/core', () => ({
  useWindowSize: () => ({ width: { value: 1440 } }),
}));

vi.mock('dashboard/composables/store', async () => {
  const { ref } = await import('vue');
  const getterValues = {
    'contacts/getContactById': () => null,
    'contacts/getUIFlags': { isFetchingInboxes: false },
    getCurrentUser: { id: 2 },
    getCurrentAccountId: 1,
    'globalConfig/get': { directUploadsEnabled: false },
    'contactConversations/getUIFlags': { isCreating: false },
    getMessageSignature: '',
    'inboxes/getInboxes': [],
  };

  return {
    useStore: () => ({ dispatch: storeDispatch }),
    useMapGetter: key => ref(getterValues[key]),
  };
});

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    fetchSignatureFlagFromUISettings: () => false,
  }),
}));

vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('shared/helpers/mitt', () => ({
  emitter: { emit: vi.fn() },
}));

vi.mock('dashboard/helper/URLHelper', () => ({
  frontendURL: path => path,
  conversationUrl: ({ accountId, activeInbox, id }) =>
    `/accounts/${accountId}/inbox/${activeInbox}/conversation/${id}`,
}));

import ComposeNewConversationForm from './components/ComposeNewConversationForm.vue';
import ComposeConversation from './ComposeConversation.vue';

describe('ComposeConversation active WhatsApp conversation reuse', () => {
  beforeEach(() => {
    routerPush.mockClear();
    getContactableInboxes.mockReset();
    storeDispatch.mockReset();
  });

  it('opens the active conversation instead of leaving the new conversation form open', async () => {
    const wrapper = shallowMount(ComposeConversation, {
      props: { isModal: true },
      global: {
        directives: { onClickOutside: {} },
      },
    });
    await wrapper.vm.toggle();

    wrapper
      .getComponent(ComposeNewConversationForm)
      .vm.$emit('updateTargetInbox', {
        id: 43,
        channelType: 'Channel::Whatsapp',
        activeConversationId: 321,
      });
    await wrapper.vm.$nextTick();

    expect(routerPush).toHaveBeenCalledWith(
      '/accounts/1/inbox/43/conversation/321'
    );
    expect(wrapper.findComponent(ComposeNewConversationForm).exists()).toBe(
      false
    );
  });

  it('uses the authoritative active conversation when opened from a channel shortcut', async () => {
    getContactableInboxes.mockResolvedValue({
      data: {
        payload: [
          {
            inbox: { id: 43, channel_type: 'Channel::Whatsapp' },
            source_id: '15551234567',
            active_conversation_id: 654,
            reply_window_open: true,
          },
        ],
      },
    });
    const wrapper = shallowMount(ComposeConversation, {
      props: { isModal: true },
      global: {
        directives: { onClickOutside: {} },
      },
    });

    await wrapper.vm.openWithChannel({
      contact: { id: 7 },
      channelIdentity: {
        inboxId: 43,
        sourceId: 'AB.provider-specific-identity',
      },
    });

    expect(routerPush).toHaveBeenCalledWith(
      '/accounts/1/inbox/43/conversation/654'
    );
    expect(wrapper.findComponent(ComposeNewConversationForm).exists()).toBe(
      false
    );
  });

  it('preserves the draft and refreshes WhatsApp state after a create error', async () => {
    getContactableInboxes
      .mockResolvedValueOnce({
        data: {
          payload: [
            {
              inbox: { id: 43, channel_type: 'Channel::Whatsapp' },
              source_id: '15551234567',
              contact_inbox_id: 88,
              reply_window_open: true,
            },
          ],
        },
      })
      .mockResolvedValueOnce({
        data: {
          payload: [
            {
              inbox: { id: 43, channel_type: 'Channel::Whatsapp' },
              source_id: '15551234567',
              contact_inbox_id: 88,
              active_conversation_id: 777,
              reply_window_open: false,
            },
          ],
        },
      });
    storeDispatch.mockRejectedValue(new Error('reply window expired'));
    const wrapper = shallowMount(ComposeConversation, {
      props: { isModal: true },
      global: {
        directives: { onClickOutside: {} },
      },
    });

    await wrapper.vm.openWithChannel({
      contact: { id: 7 },
      channelIdentity: { inboxId: 43 },
    });
    const form = wrapper.getComponent(ComposeNewConversationForm);
    form.props('formState').message = 'unsent draft';
    form.props('formState').attachedFiles.push({ name: 'brochure.pdf' });
    form.vm.$emit('createConversation', {
      payload: { inboxId: 43 },
      isFromWhatsApp: false,
    });
    await flushPromises();

    const refreshedForm = wrapper.getComponent(ComposeNewConversationForm);
    expect(refreshedForm.props('formState')).toMatchObject({
      message: 'unsent draft',
      attachedFiles: [{ name: 'brochure.pdf' }],
    });
    expect(refreshedForm.props('targetInbox')).toMatchObject({
      id: 43,
      activeConversationId: 777,
      replyWindowOpen: false,
    });
  });
});
