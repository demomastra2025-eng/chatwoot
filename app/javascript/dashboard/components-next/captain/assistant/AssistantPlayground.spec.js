import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';

import AssistantPlayground from './AssistantPlayground.vue';

const mocks = vi.hoisted(() => ({
  playground: vi.fn(),
  show: vi.fn(),
  fetch: vi.fn(),
  getModelsForFeature: vi.fn(),
  getSelectedModelForFeature: vi.fn(),
  uiFlags: { fetchError: false },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, values = {}) =>
      key.replace(/\{(\w+)\}/g, (_, valueKey) => values[valueKey] ?? ''),
  }),
}));

vi.mock('dashboard/api/captain/assistant', () => ({
  default: { playground: mocks.playground, show: mocks.show },
}));

vi.mock('dashboard/store/captain/preferences', () => ({
  useCaptainConfigStore: () => ({
    fetch: mocks.fetch,
    getModelsForFeature: mocks.getModelsForFeature,
    getSelectedModelForFeature: mocks.getSelectedModelForFeature,
    uiFlags: mocks.uiFlags,
  }),
}));

const buttonStub = {
  name: 'NextButton',
  props: ['icon', 'disabled'],
  emits: ['click'],
  template:
    '<button type="button" :data-icon="icon" :disabled="disabled" @click="$emit(\'click\')" />',
};

const selectStub = {
  name: 'Select',
  props: ['modelValue', 'options', 'disabled'],
  emits: ['update:modelValue'],
  template:
    '<select :value="modelValue" :disabled="disabled" @change="$emit(\'update:modelValue\', $event.target.value)"><option v-for="option in options" :key="option.value" :value="option.value">{{ option.label }}</option></select>',
};

const mountPlayground = () =>
  mount(AssistantPlayground, {
    props: { assistantId: 4 },
    global: {
      stubs: {
        NextButton: buttonStub,
        Select: selectStub,
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
    mocks.show.mockReset().mockResolvedValue({
      data: {
        id: 4,
        usage_mode: 'external_agent',
        config: { model: 'openai/gpt-6-luna', temperature: 0.7 },
      },
    });
    mocks.fetch.mockReset().mockResolvedValue();
    mocks.getModelsForFeature.mockReset().mockReturnValue([
      {
        id: 'openai/gpt-6-luna',
        display_name: 'GPT-6 Luna',
        supports_temperature: true,
        capabilities: ['reasoning'],
      },
      {
        id: 'openai/gpt-5.4-mini',
        display_name: 'GPT-5.4 mini',
        supports_temperature: false,
        capabilities: [],
      },
    ]);
    mocks.getSelectedModelForFeature.mockReset().mockReturnValue('openai/gpt-6-luna');
    mocks.uiFlags.fetchError = false;
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
          response_latency_ms: 1245,
          reported_reasoning_tokens: 87,
        },
      });
    const wrapper = mountPlayground();

    await send(wrapper, 'Hi');
    await send(wrapper, 'Book me');

    expect(mocks.playground).toHaveBeenNthCalledWith(1, {
      assistantId: 4,
      messageContent: 'Hi',
      messageHistory: [],
      testOptions: {},
    });
    expect(mocks.playground).toHaveBeenNthCalledWith(2, {
      assistantId: 4,
      messageContent: 'Book me',
      messageHistory: [
        { role: 'user', content: 'Hi' },
        { role: 'assistant', content: 'Hello!', agent_name: 'Receptionist' },
      ],
      testOptions: {},
    });
    expect(wrapper.findAll('li').map(item => item.text())).toEqual([
      'Hi',
      'Hello!',
      'Book me',
      'Booked.',
    ]);
    expect(wrapper.text()).toContain('The patient asked for a slot.');
    expect(wrapper.text()).toContain('create_appointment');
    expect(wrapper.text()).toContain('1245');
    expect(wrapper.text()).toContain('87');
  });

  it('sends only supported per-test controls and displays provider metrics when returned', async () => {
    mocks.playground.mockResolvedValueOnce({
      data: {
        response: 'Test response',
        response_latency_ms: 920,
        reported_reasoning_tokens: 13,
      },
    });
    const wrapper = mountPlayground();
    await flushPromises();

    await wrapper.findAll('select')[0].setValue('openai/gpt-6-luna');
    await wrapper.find('input[type="checkbox"]').setValue(true);
    await wrapper.find('input[type="range"]').setValue('0.3');
    await wrapper.findAll('select')[1].setValue('high');
    await send(wrapper, 'Try this model');

    expect(mocks.playground).toHaveBeenCalledWith({
      assistantId: 4,
      messageContent: 'Try this model',
      messageHistory: [],
      testOptions: {
        model: 'openai/gpt-6-luna',
        temperature: 0.3,
        thinkingEffort: 'high',
      },
    });
    expect(wrapper.text()).toContain('920');
    expect(wrapper.text()).toContain('13');
  });

  it('disables temperature and reasoning controls when the selected model lacks registry support', async () => {
    const wrapper = mountPlayground();
    await flushPromises();

    await wrapper.findAll('select')[0].setValue('openai/gpt-5.4-mini');

    expect(wrapper.find('input[type="checkbox"]').element.disabled).toBe(true);
    expect(wrapper.find('input[type="range"]').element.disabled).toBe(true);
    expect(wrapper.findAll('select')[1].element.disabled).toBe(true);
    expect(wrapper.text()).toContain('CAPTAIN.PLAYGROUND.UNSUPPORTED_TEMPERATURE');
    expect(wrapper.text()).toContain('CAPTAIN.PLAYGROUND.UNSUPPORTED_REASONING');
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

  it('does not expose agent model controls for the internal assistant runtime', async () => {
    mocks.show.mockResolvedValueOnce({
      data: { id: 4, usage_mode: 'internal_assistant', config: {} },
    });
    const wrapper = mountPlayground();
    await flushPromises();

    expect(wrapper.find('[data-test="playground-test-settings"]').exists()).toBe(false);
  });
});
