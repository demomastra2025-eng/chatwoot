import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';

import AssistantPlayground from './AssistantPlayground.vue';

const mocks = vi.hoisted(() => ({ playground: vi.fn() }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/api/captain/assistant', () => ({
  default: { playground: mocks.playground },
}));

const buttonStub = {
  name: 'NextButton',
  props: ['icon', 'disabled'],
  emits: ['click'],
  template:
    '<button type="button" :data-icon="icon" :disabled="disabled" @click="$emit(\'click\')" />',
};

const mountPlayground = () =>
  mount(AssistantPlayground, {
    props: { assistantId: 4 },
    global: {
      stubs: {
        NextButton: buttonStub,
        MessageList: {
          name: 'MessageList',
          props: ['messages', 'isLoading'],
          template:
            '<ul><li v-for="(message, index) in messages" :key="index" :data-sender="message.sender">{{ message.content }}</li></ul>',
        },
      },
    },
  });

const send = async (wrapper, text) => {
  await wrapper.find('input').setValue(text);
  await wrapper.find('button[data-icon="i-lucide-send"]').trigger('click');
  await flushPromises();
};

describe('AssistantPlayground («Площадка»)', () => {
  beforeEach(() => {
    mocks.playground.mockReset();
  });

  it('sends the message with the conversation history and shows the answer and its trace', async () => {
    mocks.playground
      .mockResolvedValueOnce({
        data: { response: 'Hello!', agent_name: 'Receptionist' },
      })
      .mockResolvedValueOnce({
        data: {
          response: 'Booked.',
          reasoning: 'The patient asked for a slot.',
          tool_trace: [{ tool: 'create_appointment', event: 'success' }],
        },
      });
    const wrapper = mountPlayground();

    await send(wrapper, 'Hi');
    await send(wrapper, 'Book me');

    expect(mocks.playground).toHaveBeenNthCalledWith(1, {
      assistantId: 4,
      messageContent: 'Hi',
      messageHistory: [],
    });
    expect(mocks.playground).toHaveBeenNthCalledWith(2, {
      assistantId: 4,
      messageContent: 'Book me',
      messageHistory: [
        { role: 'user', content: 'Hi' },
        { role: 'assistant', content: 'Hello!', agent_name: 'Receptionist' },
      ],
    });
    expect(wrapper.findAll('li').map(item => item.text())).toEqual([
      'Hi',
      'Hello!',
      'Book me',
      'Booked.',
    ]);
    expect(wrapper.text()).toContain('The patient asked for a slot.');
    expect(wrapper.text()).toContain('create_appointment');
  });

  it('shows the error answer when the request fails and clears on reset', async () => {
    mocks.playground.mockRejectedValueOnce(new Error('timeout'));
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const wrapper = mountPlayground();

    await send(wrapper, 'Hi');

    expect(wrapper.findAll('li').map(item => item.text())).toEqual([
      'Hi',
      'CAPTAIN.COPILOT.EMPTY_MESSAGE',
    ]);

    await wrapper
      .find('button[data-icon="i-lucide-rotate-ccw"]')
      .trigger('click');
    expect(wrapper.findAll('li')).toHaveLength(0);
    expect(wrapper.text()).toContain('CAPTAIN.PLAYGROUND.TRACE_EMPTY');
  });
});
