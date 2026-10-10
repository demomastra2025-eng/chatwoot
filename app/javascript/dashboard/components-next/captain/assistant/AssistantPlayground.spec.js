import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';

import AssistantPlayground from './AssistantPlayground.vue';

const mocks = vi.hoisted(() => ({
  playground: vi.fn(),
  playgroundSession: vi.fn(),
  show: vi.fn(),
  update: vi.fn(),
  fetch: vi.fn(),
  getModelsForFeature: vi.fn(),
  getSelectedModelForFeature: vi.fn(),
  uiFlags: { fetchError: false },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, values = {}) => {
      if (key === 'CAPTAIN.PLAYGROUND.RESPONSE_LATENCY_VALUE') {
        return `${values.ms} ms`;
      }

      return key.replace(/\{(\w+)\}/g, (_, valueKey) => values[valueKey] ?? '');
    },
  }),
}));

vi.mock('dashboard/api/captain/assistant', () => ({
  default: {
    playground: mocks.playground,
    playgroundSession: mocks.playgroundSession,
    show: mocks.show,
    update: mocks.update,
  },
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

const mountPlayground = (assistantId = 4, accountId = 74) =>
  mount(AssistantPlayground, {
    props: { assistantId, accountId },
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
  await flushPromises();
  await wrapper.find('[data-test="playground-message-input"]').setValue(text);
  await wrapper.find('button[data-icon="i-lucide-send"]').trigger('click');
  await flushPromises();
};

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
};

describe('AssistantPlayground («Площадка»)', () => {
  beforeEach(() => {
    mocks.playground.mockReset();
    mocks.playgroundSession.mockReset().mockImplementation(({ mode, reset, liveOptions }) => Promise.resolve({
      data: { playground: {
        session_id: `${mode}-${reset ? 'reset' : 'session'}`,
        mode,
        live_available: true,
        scenario: { contact: { name: 'Caller', phone_number: '+77010000001', custom_attributes: {} } },
        inboxes: [{ id: 7, name: 'Test inbox', channel_type: 'Channel::Sms' }],
        message_history: [],
        ...(mode === 'live' ? { conversation_id: 42, inbox_id: 7, delivery_enabled: liveOptions?.deliveryEnabled === true } : {}),
      } },
    }));
    mocks.update.mockReset();
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
        reasoning_efforts: ['none', 'low', 'medium', 'high'],
      },
      {
        id: 'openai/gpt-5.4-mini',
        display_name: 'GPT-5.4 mini',
        supports_temperature: false,
        capabilities: [],
        reasoning_efforts: [],
      },
    ]);
    mocks.getSelectedModelForFeature
      .mockReset()
      .mockReturnValue('openai/gpt-6-luna');
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
      mode: 'trial',
      sessionId: 'trial-session',
      messageContent: 'Hi',
      messageHistory: [],
      testOptions: {},
    });
    expect(mocks.playground).toHaveBeenNthCalledWith(2, {
      assistantId: 4,
      mode: 'trial',
      sessionId: 'trial-session',
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
      mode: 'trial',
      sessionId: 'trial-session',
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
    expect(wrapper.text()).toContain(
      'CAPTAIN.PLAYGROUND.UNSUPPORTED_TEMPERATURE'
    );
    expect(wrapper.text()).toContain(
      'CAPTAIN.PLAYGROUND.UNSUPPORTED_REASONING'
    );
  });

  it('uses the saved model metadata outside the curated list and sends zero temperature without saving config', async () => {
    const savedConfig = { model: 'vendor/saved-model', temperature: 0 };
    mocks.show.mockResolvedValueOnce({
      data: {
        id: 4,
        usage_mode: 'external_agent',
        config: savedConfig,
        playground_model: {
          id: 'vendor/saved-model',
          display_name: 'Saved model',
          supports_temperature: true,
          reasoning_efforts: ['low', 'high'],
        },
      },
    });
    mocks.playground.mockResolvedValue({ data: { response: 'Test response' } });
    const wrapper = mountPlayground();
    await flushPromises();

    expect(wrapper.find('input[type="checkbox"]').element.disabled).toBe(false);
    expect(wrapper.find('input[type="range"]').element.value).toBe('0');
    expect(
      wrapper
        .findAll('select')[1]
        .findAll('option')
        .map(option => option.element.value)
    ).toEqual(['', 'low', 'high']);
    expect(
      wrapper
        .findAll('select')[0]
        .findAll('option')
        .filter(option => option.element.value === 'vendor/saved-model')
    ).toHaveLength(1);
    await wrapper.find('input[type="checkbox"]').setValue(true);
    await wrapper.findAll('select')[1].setValue('high');
    await send(wrapper, 'Test the saved model');

    expect(mocks.playground).toHaveBeenCalledWith({
      assistantId: 4,
      mode: 'trial',
      sessionId: 'trial-session',
      messageContent: 'Test the saved model',
      messageHistory: [],
      testOptions: { temperature: 0, thinkingEffort: 'high' },
    });
    expect(savedConfig).toEqual({
      model: 'vendor/saved-model',
      temperature: 0,
    });
    expect(mocks.update).not.toHaveBeenCalled();
  });

  it('uses metadata for the server-resolved default and keeps unknown capabilities disabled', async () => {
    mocks.show.mockResolvedValueOnce({
      data: {
        id: 4,
        usage_mode: 'external_agent',
        config: { model: 'removed/model', temperature: null },
        playground_model: {
          id: 'vendor/default-model',
          supports_temperature: false,
          reasoning_efforts: [],
        },
      },
    });
    const wrapper = mountPlayground();
    await flushPromises();

    expect(wrapper.find('input[type="checkbox"]').element.disabled).toBe(true);
    expect(wrapper.findAll('select')[1].element.disabled).toBe(true);
    expect(wrapper.find('input[type="range"]').element.value).toBe('1');
    expect(
      wrapper
        .findAll('select')[0]
        .find('option[value="vendor/default-model"]')
        .exists()
    ).toBe(true);
    expect(
      wrapper
        .findAll('select')[0]
        .find('option[value="removed/model"]')
        .exists()
    ).toBe(false);
  });

  it('clears an effort when switching to a model that does not support that effort', async () => {
    mocks.getModelsForFeature.mockReturnValue([
      {
        id: 'openai/gpt-6-luna',
        supports_temperature: true,
        reasoning_efforts: ['none', 'high'],
      },
      {
        id: 'vendor/mandatory-model',
        supports_temperature: true,
        reasoning_efforts: ['medium'],
      },
    ]);
    mocks.playground.mockResolvedValue({ data: { response: 'Test response' } });
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper.findAll('select')[1].setValue('none');
    await wrapper.findAll('select')[0].setValue('vendor/mandatory-model');
    await flushPromises();

    expect(wrapper.findAll('select')[1].element.value).toBe('');
    expect(
      wrapper.findAll('select')[1].find('option[value="none"]').exists()
    ).toBe(false);
    await send(wrapper, 'Use this model');
    expect(mocks.playground.mock.calls[0][0].testOptions).toEqual({
      model: 'vendor/mandatory-model',
    });
  });

  it('keeps compact panels and settings in scrollable flow with a shrinkable message area', async () => {
    const wrapper = mountPlayground();
    await flushPromises();

    expect(wrapper.find('[data-test="playground-layout"]').classes()).toContain(
      'overflow-y-auto'
    );
    expect(wrapper.find('[data-test="playground-chat"]').classes()).toContain(
      'min-h-0'
    );
    expect(
      wrapper.find('[data-test="playground-chat"]').classes()
    ).not.toContain('min-h-[32rem]');
    expect(wrapper.find('[data-test="playground-panels"]').classes()).toContain(
      'shrink-0'
    );
    expect(
      wrapper.find('[data-test="playground-test-settings"]').classes()
    ).toContain('shrink-0');
    expect(wrapper.find('[data-test="playground-trace"]').classes()).toContain(
      'max-h-80'
    );
    expect(wrapper.find('input').classes()).toContain('min-w-0');
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

    expect(
      wrapper.find('[data-test="playground-test-settings"]').exists()
    ).toBe(false);
  });

  it('retries failed settings metadata with a forced fetch', async () => {
    mocks.fetch
      .mockRejectedValueOnce(new Error('temporary network error'))
      .mockResolvedValueOnce();
    const wrapper = mountPlayground();
    await flushPromises();

    expect(wrapper.text()).toContain('CAPTAIN.PLAYGROUND.TEST_SETTINGS_ERROR');
    const retryButton = wrapper
      .findAll('button')
      .find(button => button.text() === 'DESIGN_SYSTEM.STATE.RETRY');
    expect(retryButton).toBeDefined();

    await retryButton.trigger('click');
    await flushPromises();

    expect(mocks.fetch).toHaveBeenNthCalledWith(1, {
      clientMetadataOnly: true,
    });
    expect(mocks.fetch).toHaveBeenNthCalledWith(2, {
      clientMetadataOnly: true,
      force: true,
    });
    expect(wrapper.text()).not.toContain(
      'CAPTAIN.PLAYGROUND.TEST_SETTINGS_ERROR'
    );
  });

  it('ignores stale settings after route reuse and keeps the new assistant model capabilities', async () => {
    const oldAssistant = deferred();
    mocks.show.mockImplementation(assistantId => {
      if (assistantId === 4) return oldAssistant.promise;

      return Promise.resolve({
        data: {
          id: assistantId,
          usage_mode: 'external_agent',
          config: { model: 'openai/gpt-5.4-mini', temperature: 0.4 },
        },
      });
    });
    const wrapper = mountPlayground(4);
    await flushPromises();

    await wrapper.setProps({ assistantId: 5 });
    await flushPromises();

    expect(
      wrapper.find('[data-test="playground-test-settings"]').exists()
    ).toBe(true);
    expect(wrapper.find('input[type="checkbox"]').element.disabled).toBe(true);
    expect(wrapper.find('input[type="range"]').element.disabled).toBe(true);
    expect(wrapper.findAll('select')[1].element.disabled).toBe(true);

    oldAssistant.resolve({
      data: {
        id: 4,
        usage_mode: 'external_agent',
        config: { model: 'openai/gpt-6-luna', temperature: 0.8 },
      },
    });
    await flushPromises();

    expect(
      wrapper.find('[data-test="playground-test-settings"]').exists()
    ).toBe(true);
    expect(wrapper.find('input[type="checkbox"]').element.disabled).toBe(true);
    expect(wrapper.find('input[type="range"]').element.disabled).toBe(true);
    expect(wrapper.findAll('select')[1].element.disabled).toBe(true);
  });

  it('keeps internal settings hidden when a previous external assistant load finishes late', async () => {
    const oldAssistant = deferred();
    mocks.show.mockImplementation(assistantId => {
      if (assistantId === 4) return oldAssistant.promise;

      return Promise.resolve({
        data: { id: assistantId, usage_mode: 'internal_assistant', config: {} },
      });
    });
    const wrapper = mountPlayground(4);
    await wrapper.setProps({ assistantId: 5 });
    await flushPromises();

    expect(
      wrapper.find('[data-test="playground-test-settings"]').exists()
    ).toBe(false);

    oldAssistant.resolve({
      data: {
        id: 4,
        usage_mode: 'external_agent',
        config: { model: 'openai/gpt-6-luna', temperature: 0.8 },
      },
    });
    await flushPromises();

    expect(
      wrapper.find('[data-test="playground-test-settings"]').exists()
    ).toBe(false);
  });

  it('does not append a late response to the next assistant session', async () => {
    const oldResponse = deferred();
    mocks.show.mockImplementation(assistantId =>
      Promise.resolve({
        data: {
          id: assistantId,
          usage_mode: 'external_agent',
          config: { model: 'openai/gpt-6-luna', temperature: 0.7 },
        },
      })
    );
    mocks.playground.mockImplementation(({ assistantId }) => {
      if (assistantId === 4) return oldResponse.promise;

      return Promise.resolve({ data: { response: 'New assistant response' } });
    });
    const wrapper = mountPlayground(4);
    await flushPromises();

    await wrapper.find('input').setValue('Old assistant request');
    await wrapper.find('button[data-icon="i-lucide-send"]').trigger('click');
    await flushPromises();

    await wrapper.setProps({ assistantId: 5 });
    await flushPromises();
    expect(wrapper.findAll('li')).toHaveLength(0);

    await send(wrapper, 'New assistant request');
    expect(wrapper.findAll('li').map(item => item.text())).toEqual([
      'New assistant request',
      'New assistant response',
    ]);

    oldResponse.resolve({ data: { response: 'Old assistant response' } });
    await flushPromises();

    expect(wrapper.findAll('li').map(item => item.text())).toEqual([
      'New assistant request',
      'New assistant response',
    ]);
  });

  it('rejects old-account metadata when only the account route changes', async () => {
    const oldAssistant = deferred();
    mocks.show.mockReturnValueOnce(oldAssistant.promise).mockResolvedValueOnce({
      data: {
        id: 4,
        usage_mode: 'external_agent',
        config: {},
        playground_model: {
          id: 'vendor/new-default',
          supports_temperature: false,
          reasoning_efforts: [],
        },
      },
    });
    const wrapper = mountPlayground(4, 74);
    await wrapper.setProps({ accountId: 75 });
    await flushPromises();

    oldAssistant.resolve({
      data: {
        id: 4,
        usage_mode: 'external_agent',
        config: { model: 'vendor/previous-model', temperature: 0.8 },
        playground_model: {
          id: 'vendor/previous-model',
          supports_temperature: true,
          reasoning_efforts: ['high'],
        },
      },
    });
    await flushPromises();

    expect(wrapper.find('input[type="checkbox"]').element.disabled).toBe(true);
    expect(wrapper.find('input[type="range"]').element.value).toBe('1');
    expect(
      wrapper
        .findAll('select')[0]
        .find('option[value="vendor/previous-model"]')
        .exists()
    ).toBe(false);
  });

  it('clears account history and rejects a late reply after account-only route reuse', async () => {
    const oldResponse = deferred();
    mocks.playground
      .mockReturnValueOnce(oldResponse.promise)
      .mockResolvedValueOnce({
        data: { response: 'Current workspace response' },
      });
    const wrapper = mountPlayground(4, 74);
    await flushPromises();
    await wrapper.find('input').setValue('Previous workspace request');
    await wrapper.find('button[data-icon="i-lucide-send"]').trigger('click');
    await wrapper.setProps({ accountId: 75 });
    await flushPromises();

    expect(wrapper.findAll('li')).toHaveLength(0);
    await send(wrapper, 'Current workspace request');
    expect(mocks.playground.mock.calls[1][0].messageHistory).toEqual([]);
    oldResponse.resolve({ data: { response: 'Previous workspace response' } });
    await flushPromises();

    expect(wrapper.findAll('li').map(item => item.text())).toEqual([
      'Current workspace request',
      'Current workspace response',
    ]);
  });

  it('keeps reset conversation empty when the previous request finishes', async () => {
    const oldResponse = deferred();
    mocks.playground.mockReturnValueOnce(oldResponse.promise);
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper.find('input').setValue('Previous request');
    await wrapper.find('button[data-icon="i-lucide-send"]').trigger('click');
    await wrapper
      .find('button[data-icon="i-lucide-rotate-ccw"]')
      .trigger('click');
    oldResponse.resolve({ data: { response: 'Previous response' } });
    await flushPromises();

    expect(wrapper.findAll('li')).toHaveLength(0);
    expect(wrapper.text()).toContain('CAPTAIN.PLAYGROUND.TRACE_EMPTY');
  });

  it('keeps Trial and Live history separate in one window and starts Live with external delivery off', async () => {
    mocks.playground.mockResolvedValue({ data: { response: 'Trial answer' } });
    const wrapper = mountPlayground();
    await send(wrapper, 'Trial question');
    await wrapper.find('[data-test="playground-mode-live"]').trigger('click');
    await flushPromises();

    expect(wrapper.findAll('li')).toHaveLength(0);
    expect(wrapper.find('[data-test="playground-live-warning"]').exists()).toBe(true);
    expect(wrapper.find('[data-test="playground-external-delivery"]').element.checked).toBe(false);
    expect(mocks.playgroundSession).toHaveBeenLastCalledWith({
      assistantId: 4, mode: 'live', sessionId: undefined, reset: false,
      liveOptions: { inboxId: '7', deliveryEnabled: false, testNumber: '' },
    });
    mocks.playground.mockResolvedValueOnce({ data: { response: 'Live answer' } });
    await send(wrapper, 'Live question');
    expect(mocks.playground.mock.lastCall[0]).toMatchObject({
      mode: 'live', sessionId: 'live-session', conversationId: 42, messageHistory: [],
      liveOptions: { deliveryEnabled: false },
    });

    await wrapper.find('[data-test="playground-mode-trial"]').trigger('click');
    await flushPromises();
    expect(wrapper.findAll('li').map(item => item.text())).toEqual(['Trial question', 'Trial answer']);
    expect(wrapper.find('[data-test="playground-live-warning"]').exists()).toBe(false);
  });

  it('does not put a late Trial answer into Live or send Trial references to Live', async () => {
    const oldResponse = deferred();
    mocks.playground.mockReturnValueOnce(oldResponse.promise);
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper.find('[data-test="playground-message-input"]').setValue('Pending trial');
    await wrapper.find('button[data-icon="i-lucide-send"]').trigger('click');
    await wrapper.find('[data-test="playground-mode-live"]').trigger('click');
    await flushPromises();
    oldResponse.resolve({ data: { response: 'Late trial response' } });
    await flushPromises();
    expect(wrapper.findAll('li')).toHaveLength(0);

    mocks.playground.mockResolvedValueOnce({ data: { response: 'Live response' } });
    await send(wrapper, 'Live request');
    expect(mocks.playground.mock.lastCall[0]).toMatchObject({ mode: 'live', sessionId: 'live-session', conversationId: 42 });
    expect(wrapper.text()).not.toContain('Late trial response');
  });

  it('sends the controlled test phone only after an explicit Live opt-in', async () => {
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper.find('[data-test="playground-mode-live"]').trigger('click');
    await flushPromises();
    await wrapper.find('[data-test="playground-external-delivery"]').setValue(true);
    await wrapper.find('[data-test="playground-controlled-number"]').setValue('+77015551234');
    mocks.playground.mockResolvedValueOnce({ data: { response: 'Reply' } });
    await send(wrapper, 'Controlled delivery');
    expect(mocks.playground.mock.lastCall[0].liveOptions).toEqual({
      inboxId: '7', deliveryEnabled: true, testNumber: '+77015551234',
    });
  });

  it('keeps scenario data collapsed and resets its server state without changing model controls', async () => {
    const wrapper = mountPlayground();
    await flushPromises();
    expect(wrapper.find('[data-test="playground-scenario-editor"]').exists()).toBe(false);
    await wrapper.findAll('select')[0].setValue('openai/gpt-6-luna');
    await wrapper.find('[data-test="playground-scenario-toggle"]').trigger('click');
    await wrapper.find('[data-test="scenario-contact-name"]').setValue('Edited caller');
    await wrapper.find('[data-test="playground-scenario-save"]').trigger('click');
    await flushPromises();
    expect(mocks.playgroundSession.mock.lastCall[0].scenario.contact.name).toBe('Edited caller');

    await wrapper.find('[data-test="playground-trial-reset"]').trigger('click');
    await flushPromises();
    expect(mocks.playgroundSession.mock.lastCall[0]).toMatchObject({ reset: true, mode: 'trial', sessionId: 'trial-session' });
    expect(wrapper.findAll('select')[0].element.value).toBe('openai/gpt-6-luna');
    expect(mocks.update).not.toHaveBeenCalled();
  });

  it('waits for an in-flight turn before resetting the server session and ignores its late answer', async () => {
    const pending = deferred();
    mocks.playground.mockReturnValueOnce(pending.promise);
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper.find('[data-test="playground-message-input"]').setValue('Pending');
    await wrapper.find('button[data-icon="i-lucide-send"]').trigger('click');
    await wrapper.find('button[data-icon="i-lucide-rotate-ccw"]').trigger('click');
    expect(mocks.playgroundSession).toHaveBeenCalledTimes(1);
    pending.resolve({ data: { response: 'Old answer' } });
    await flushPromises();
    expect(mocks.playgroundSession.mock.lastCall[0].reset).toBe(true);
    expect(wrapper.findAll('li')).toHaveLength(0);
  });

  it('requires a server session before sending and provides retry after a failed session request', async () => {
    mocks.playgroundSession.mockRejectedValueOnce(new Error('Unavailable'));
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper.find('[data-test="playground-message-input"]').setValue('Cannot send yet');
    expect(wrapper.find('button[data-icon="i-lucide-send"]').element.disabled).toBe(true);
    await wrapper.find('[data-test="playground-session-retry"]').trigger('click');
    await flushPromises();
    expect(wrapper.find('button[data-icon="i-lucide-send"]').element.disabled).toBe(false);
    expect(mocks.playground).not.toHaveBeenCalled();
  });
});
