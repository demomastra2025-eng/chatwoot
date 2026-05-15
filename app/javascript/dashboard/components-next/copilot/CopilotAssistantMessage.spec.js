import { describe, expect, it } from 'vitest';
import { mount } from '@vue/test-utils';

import CopilotAssistantMessage from './CopilotAssistantMessage.vue';

const mountComponent = props =>
  mount(CopilotAssistantMessage, {
    props: {
      isLastMessage: true,
      conversationInboxType: 'Channel::WebWidget',
      message: {
        content: 'Created the contact.',
        reply_suggestion: false,
        ui_actions: [
          {
            type: 'open_contact',
            label: 'Open contact',
            target_id: '42',
          },
        ],
      },
      ...props,
    },
    global: {
      stubs: {
        Button: {
          props: ['label'],
          emits: ['click'],
          template:
            '<button type="button" @click="$emit(\'click\')">{{ label }}</button>',
        },
      },
      directives: {
        dompurifyHtml: (el, binding) => {
          el.innerHTML = binding.value;
        },
      },
      mocks: {
        $t: key => key,
      },
    },
  });

describe('CopilotAssistantMessage', () => {
  it('renders assistant UI action buttons and emits the selected action', async () => {
    const wrapper = mountComponent();
    const button = wrapper.find('button');

    expect(wrapper.text()).toContain('Created the contact.');
    expect(button.text()).toBe('Open contact');

    await button.trigger('click');

    expect(wrapper.emitted('uiAction')?.[0]).toEqual([
      { type: 'open_contact', label: 'Open contact', targetId: '42' },
    ]);
  });
});
