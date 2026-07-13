import { shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const copilotState = vi.hoisted(() => ({ isActive: false }));

vi.mock('dashboard/composables/useCopilotReply', async () => {
  const { ref } = await vi.importActual('vue');
  return {
    useCopilotReply: () => ({
      isActive: ref(copilotState.isActive),
      isButtonDisabled: ref(false),
      reset: vi.fn(),
      accept: vi.fn(() => ''),
    }),
  };
});

vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

import ActionButtons from './ActionButtons.vue';
import ComposeNewConversationForm from './ComposeNewConversationForm.vue';
import MessageEditor from './MessageEditor.vue';

const mountComponent = overrides =>
  shallowMount(ComposeNewConversationForm, {
    props: {
      contacts: [],
      selectedContact: {
        id: 7,
        phone_number: '+77010000000',
        contactInboxes: [],
      },
      targetInbox: {
        id: 42,
        channelType: 'Channel::Voice',
        medium: 'voice',
      },
      currentUser: { id: 1 },
      isFetchingInboxes: false,
      contactConversationsUiFlags: { isCreating: false },
      contactsUiFlags: { isFetchingInboxes: false },
      formState: {
        message: 'Draft that must not be sent as a call',
        subject: '',
        ccEmails: '',
        bccEmails: '',
        attachedFiles: [],
      },
      ...overrides,
    },
  });

describe('ComposeNewConversationForm voice mode', () => {
  beforeEach(() => {
    copilotState.isActive = false;
  });

  it('removes the message editor and passes the selected call target to actions', async () => {
    const wrapper = mountComponent();

    expect(wrapper.findComponent(MessageEditor).exists()).toBe(false);
    const actions = wrapper.getComponent(ActionButtons);
    expect(actions.props()).toMatchObject({
      channelType: 'Channel::Voice',
      inboxId: 42,
      contactId: 7,
      contactPhone: '+77010000000',
    });

    actions.vm.$emit('voiceCallStarted');
    await wrapper.vm.$nextTick();
    expect(wrapper.emitted('discard')).toHaveLength(1);
    expect(wrapper.emitted('createConversation')).toBeUndefined();
  });

  it('keeps native call actions visible when Copilot was active before selecting voice', () => {
    copilotState.isActive = true;

    const wrapper = mountComponent();

    expect(wrapper.findComponent(ActionButtons).exists()).toBe(true);
    expect(wrapper.find('copilot-reply-bottom-panel-stub').exists()).toBe(
      false
    );
  });

  it('keeps the message editor for a regular channel', () => {
    const wrapper = mountComponent({
      targetInbox: {
        id: 43,
        channelType: 'Channel::Api',
        medium: 'api',
      },
      contactsUiFlags: { isFetchingInboxes: true },
    });

    expect(wrapper.findComponent(MessageEditor).exists()).toBe(true);
  });
});
