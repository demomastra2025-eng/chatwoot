import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    fetchSignatureFlagFromUISettings: vi.fn(() => false),
    setSignatureFlagForInbox: vi.fn(),
    isEditorHotKeyEnabled: vi.fn(() => false),
  }),
}));

vi.mock('dashboard/composables/useFileUpload', () => ({
  useFileUpload: () => ({ onFileUpload: vi.fn() }),
}));

vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

vi.mock('@vueuse/core', () => ({
  useEventListener: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) =>
      `${key}${params.keyCode ? `:${params.keyCode}` : ''}`,
  }),
}));

import VoiceCallButton from 'dashboard/components-next/Contacts/VoiceCallButton.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ActionButtons from './ActionButtons.vue';

const mountComponent = props =>
  shallowMount(ActionButtons, {
    props: {
      attachedFiles: [],
      ...props,
    },
  });

describe('ActionButtons', () => {
  it('shows only the native call action for a selected voice inbox', async () => {
    const wrapper = mountComponent({
      channelType: 'Channel::Voice',
      hasSelectedInbox: true,
      inboxId: 42,
      contactId: 7,
      contactPhone: '+77010000000',
    });

    const voiceCallButton = wrapper.getComponent(VoiceCallButton);
    expect(voiceCallButton.props()).toMatchObject({
      contactId: 7,
      phone: '+77010000000',
      inboxId: 42,
    });

    const regularSendButton = wrapper
      .findAllComponents(Button)
      .find(
        button =>
          button.props('label') ===
          'COMPOSE_NEW_CONVERSATION.FORM.ACTION_BUTTONS.SEND:↵'
      );
    expect(regularSendButton).toBeUndefined();
    expect(
      wrapper
        .findAllComponents(Button)
        .some(button =>
          [
            'i-lucide-smile-plus',
            'i-lucide-plus',
            'i-lucide-signature',
          ].includes(button.props('icon'))
        )
    ).toBe(false);

    voiceCallButton.vm.$emit('callInitiated');
    await wrapper.vm.$nextTick();
    expect(wrapper.emitted('voiceCallStarted')).toHaveLength(1);
  });

  it('shows a disabled call action when the selected contact has no phone', () => {
    const wrapper = mountComponent({
      channelType: 'Channel::Voice',
      hasSelectedInbox: true,
      inboxId: 42,
      contactId: 7,
      contactPhone: '',
    });

    expect(wrapper.findComponent(VoiceCallButton).exists()).toBe(false);
    const disabledCallButton = wrapper.get(
      '[data-testid="new-conversation-call-button-disabled"]'
    );
    expect(disabledCallButton.attributes('disabled')).toBeDefined();
  });

  it('keeps the normal send action for non-call channels', () => {
    const wrapper = mountComponent({
      channelType: 'Channel::Api',
      hasSelectedInbox: true,
    });

    expect(wrapper.findComponent(VoiceCallButton).exists()).toBe(false);
    expect(
      wrapper
        .findAllComponents(Button)
        .some(
          button =>
            button.props('label') ===
            'COMPOSE_NEW_CONVERSATION.FORM.ACTION_BUTTONS.SEND:↵'
        )
    ).toBe(true);
  });
});
