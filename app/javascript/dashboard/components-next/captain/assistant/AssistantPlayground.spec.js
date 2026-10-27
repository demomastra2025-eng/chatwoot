import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import PlaygroundIndex from 'dashboard/routes/dashboard/captain/playground/Index.vue';
import AssistantPlayground from './AssistantPlayground.vue';

const mocks = vi.hoisted(() => ({
  playground: vi.fn(),
  playgroundSession: vi.fn(),
  playgroundPermissions: vi.fn(),
  confirmPlaygroundAction: vi.fn(),
  fetch: vi.fn(),
  getModelsForFeature: vi.fn(),
  getSelectedModelForFeature: vi.fn(),
  uiFlags: { fetchError: false },
  inboxes: [],
  assistants: [],
  assistantUIFlags: { fetchingList: false },
  dispatch: vi.fn(),
}));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, te: () => true }),
}));
vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => ({ params: { accountId: '74' } }),
}));
vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({
    checkPermissions: () => true,
    shouldShowPaywall: () => false,
  }),
}));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: key => ({
    get value() {
      if (key === 'captainAssistants/getRecords') return mocks.assistants;
      if (key === 'captainAssistants/getUIFlags') return mocks.assistantUIFlags;
      return mocks.inboxes;
    },
  }),
}));
vi.mock('dashboard/api/captain/playground', () => ({
  default: {
    message: (...args) => mocks.playground(...args),
    session: (...args) => mocks.playgroundSession(...args),
    permissions: (...args) => mocks.playgroundPermissions(...args),
    confirmAction: (...args) => mocks.confirmPlaygroundAction(...args),
  },
}));
vi.mock('dashboard/store/captain/preferences', () => ({
  useCaptainConfigStore: () => mocks,
}));
const button = {
  name: 'NextButton',
  props: ['disabled', 'label'],
  emits: ['click'],
  template:
    '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};
const select = {
  props: ['modelValue', 'options', 'disabled'],
  emits: ['update:modelValue'],
  template:
    '<select :value="modelValue" :disabled="disabled" @change="$emit(\'update:modelValue\', $event.target.value)"><option v-for="option in options" :key="option.value" :value="option.value">{{ option.label }}</option></select>',
};
const scenario = () => ({
  contact: { id: -101, name: 'Caller', custom_attributes: {} },
  patients: [],
  deals: [],
  appointments: [],
  resources: [],
  services: [],
  custom_fields: [],
  companies: [],
  knowledge_documents: [],
});
const payload = (extra = {}) => ({
  mode: 'workspace',
  session_id: 'session-1',
  scenario: scenario(),
  message_history: [],
  real_data_read: false,
  real_data_write: false,
  action_previews: [],
  ...extra,
});
const approval = () => ({
  id: 'approval-1',
  digest: 'exact-digest',
  tool: 'update_deal',
  target: { deal_id: { id: 18, name: 'Named deal' } },
  arguments: { deal_id: 18, title: 'New title' },
});
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((a, b) => {
    resolve = a;
    reject = b;
  });
  return { promise, resolve, reject };
};
const mountPlayground = ({ realMessages = false } = {}) =>
  mount(AssistantPlayground, {
    props: { accountId: 74 },
    global: {
      directives: {
        'dompurify-html': (el, binding) => {
          el.innerHTML = binding.value ?? '';
        },
      },
      stubs: {
        Button: button,
        NextButton: button,
        Select: select,
        Avatar: true,
        MessageList: realMessages
          ? false
          : {
              props: ['messages'],
              template:
                '<ul><li v-for="(message,index) in messages" :key="index">{{ message.content }}</li></ul>',
            },
        PlaygroundScenarioEditor: {
          name: 'PlaygroundScenarioEditor',
          props: ['modelValue'],
          emits: ['update:modelValue'],
          template: '<div />',
        },
      },
    },
  });
const send = async (wrapper, text = 'Hello') => {
  await wrapper.get('[data-test="playground-message-input"]').setValue(text);
  await wrapper.get('form').trigger('submit');
  await flushPromises();
};
// Block rules: a frame is an outline or a full border, or a rounded element
// with a filled background. Real form controls and buttons do not count.
const CONTROL_TAGS = ['BUTTON', 'INPUT', 'SELECT', 'TEXTAREA'];
const isFramed = element => {
  if (CONTROL_TAGS.includes(element.tagName)) return false;
  const classes = Array.from(element.classList);
  const rounded = classes.some(
    name => /^rounded(-|$)/.test(name) && name !== 'rounded-none'
  );
  const filled = classes.some(name => name.startsWith('bg-'));
  return (
    classes.includes('outline') ||
    classes.includes('border') ||
    (rounded && filled)
  );
};

beforeEach(() => {
  Object.values(mocks).forEach(value => value?.mockReset?.());
  mocks.uiFlags.fetchError = false;
  mocks.assistants = [];
  mocks.assistantUIFlags = { fetchingList: false };
  mocks.inboxes = [
    { id: 7, name: 'WhatsApp клиники', channel_type: 'Channel::Whatsapp' },
    { id: 8, name: 'Telegram клиники', channel_type: 'Channel::Telegram' },
    { id: 9, name: 'Телефон', channel_type: 'Channel::Voice' },
  ];
  mocks.fetch.mockResolvedValue();
  mocks.getModelsForFeature.mockReturnValue([
    {
      id: 'provider/model',
      supports_temperature: true,
      reasoning_efforts: ['low', 'high'],
    },
  ]);
  mocks.getSelectedModelForFeature.mockReturnValue('provider/model');
  mocks.playgroundSession.mockImplementation(({ reset }) =>
    Promise.resolve({
      data: {
        playground: payload({ session_id: reset ? 'reset-1' : 'session-1' }),
      },
    })
  );
  mocks.playgroundPermissions.mockImplementation(({ read, write }) =>
    Promise.resolve({
      data: {
        playground: payload({
          real_data_read: read,
          real_data_write: read && write,
        }),
      },
    })
  );
  mocks.playground.mockResolvedValue({
    data: { response: 'Reply', playground: payload() },
  });
  mocks.confirmPlaygroundAction.mockResolvedValue({
    data: {
      success: true,
      playground: payload({ real_data_read: true, real_data_write: true }),
    },
  });
});

describe('one Playground workspace', () => {
  it('keeps a delegated reply in the same chat and shows its responding agent and task state', async () => {
    mocks.playground.mockResolvedValueOnce({
      data: {
        response: 'I can help with the invoice.',
        agent_id: 5,
        agent_name: 'assistant_5',
        agent_display_name: 'Billing',
        agent_tasks: [
          {
            id: 'task-1',
            title: 'Check invoice',
            status: 'waiting',
            assistant_id: 5,
          },
        ],
        playground: payload(),
      },
    });
    const wrapper = mountPlayground({ realMessages: true });
    await flushPromises();
    await send(wrapper, 'Please check the invoice');
    expect(
      wrapper.get('[data-test="playground-responding-agent"]').text()
    ).toBe('Billing');
    expect(
      wrapper.get('[data-test="playground-agent-tasks"]').text()
    ).toContain('Check invoice');
    expect(
      wrapper.get('[data-test="playground-agent-tasks"]').text()
    ).toContain('CAPTAIN.PLAYGROUND.TASK_STATUS.WAITING');
    expect(mocks.playgroundSession).toHaveBeenCalledTimes(1);
    wrapper.unmount();
  });

  it('renders provider and delegated action failures as text through the actual message formatter', async () => {
    mocks.playground.mockResolvedValueOnce({
      data: {
        response: 'conversation_handoff_due_to_provider_error',
        error_class: 'ProviderError',
        error_message: 'Internal provider diagnostic',
        playground: payload(),
      },
    });
    const wrapper = mountPlayground({ realMessages: true });
    await flushPromises();
    await send(wrapper);
    expect(wrapper.text()).toContain('CAPTAIN.PLAYGROUND.PROVIDER_ERROR');
    expect(wrapper.text()).not.toContain(
      'conversation_handoff_due_to_provider_error'
    );
    expect(wrapper.text()).not.toContain('Internal provider diagnostic');
    await wrapper.vm.setPermissions(true, true);
    mocks.confirmPlaygroundAction.mockResolvedValueOnce({
      data: {
        success: false,
        result: { success: false, error: 'The appointment changed' },
        playground: payload({ real_data_read: true, real_data_write: true }),
      },
    });
    await wrapper.vm.confirmAction(approval());
    await flushPromises();
    expect(wrapper.text()).toContain('The appointment changed');
    expect(wrapper.text()).not.toContain('[object Object]');
    wrapper.unmount();
  });

  it('uses permission toggles and keeps write access hidden/off until reading is enabled', async () => {
    const wrapper = mountPlayground();
    await flushPromises();
    expect(
      wrapper.get('[data-test="playground-settings"]').find('select').exists()
    ).toBe(true);
    expect(wrapper.find('[data-test="playground-real-write"]').exists()).toBe(
      false
    );
    const readToggle = wrapper.get('[data-test="playground-real-read"]');
    expect(readToggle.attributes('role')).toBe('switch');
    expect(readToggle.attributes('aria-label')).toBe(
      'CAPTAIN.PLAYGROUND.REAL_READ'
    );
    expect(readToggle.attributes('aria-checked')).toBe('false');
    expect(wrapper.find('[data-test="model-temperature"]').exists()).toBe(true);
    await readToggle.trigger('click');
    await flushPromises();
    expect(readToggle.attributes('aria-checked')).toBe('true');
    const writeToggle = wrapper.get('[data-test="playground-real-write"]');
    expect(writeToggle.attributes('role')).toBe('switch');
    expect(writeToggle.attributes('aria-label')).toBe(
      'CAPTAIN.PLAYGROUND.REAL_WRITE'
    );
    expect(writeToggle.attributes('aria-checked')).toBe('false');
    await writeToggle.trigger('click');
    await flushPromises();
    expect(writeToggle.attributes('aria-checked')).toBe('true');
    expect(
      wrapper.find('[data-test="playground-write-warning"]').exists()
    ).toBe(true);
    expect(mocks.playgroundPermissions).toHaveBeenLastCalledWith({
      sessionId: 'session-1',
      read: true,
      write: true,
    });
    await readToggle.trigger('click');
    await flushPromises();
    expect(readToggle.attributes('aria-checked')).toBe('false');
    expect(wrapper.find('[data-test="playground-real-write"]').exists()).toBe(
      false
    );
    expect(mocks.playgroundPermissions).toHaveBeenLastCalledWith({
      sessionId: 'session-1',
      read: false,
      write: false,
    });
    wrapper.unmount();
  });

  it('does not resurrect ON permissions or revoked previews from an older turn response after OFF', async () => {
    const turn = deferred();
    mocks.playground.mockReturnValue(turn.promise);
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper.vm.setPermissions(true, true);
    await send(wrapper);
    await wrapper.vm.setPermissions(false, false);
    turn.resolve({
      data: {
        response: 'Stale reply',
        playground: payload({
          real_data_read: true,
          real_data_write: true,
          action_previews: [approval()],
        }),
      },
    });
    await flushPromises();
    expect(
      wrapper
        .get('[data-test="playground-real-read"]')
        .attributes('aria-checked')
    ).toBe('false');
    expect(wrapper.find('[data-test="playground-real-write"]').exists()).toBe(
      false
    );
    expect(
      wrapper.find('[data-test="playground-action-previews"]').exists()
    ).toBe(false);
    expect(wrapper.text()).not.toContain('Stale reply');
    expect(
      wrapper.get('[data-test="playground-message-input"]').element.disabled
    ).toBe(false);
    wrapper.unmount();
  });

  it('blocks further turns when OFF was not acknowledged and only resumes after a successful revocation retry', async () => {
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper.vm.setPermissions(true, true);
    mocks.playgroundPermissions.mockRejectedValueOnce(new Error('offline'));
    expect(await wrapper.vm.setPermissions(false, false)).toBe(false);
    await flushPromises();
    expect(
      wrapper.get('[data-test="playground-message-input"]').element.disabled
    ).toBe(true);
    expect(wrapper.find('[data-test="playground-revoke-retry"]').exists()).toBe(
      true
    );
    await send(wrapper);
    expect(mocks.playground).not.toHaveBeenCalled();
    await wrapper.get('[data-test="playground-revoke-retry"]').trigger('click');
    await flushPromises();
    expect(
      wrapper.get('[data-test="playground-message-input"]').element.disabled
    ).toBe(false);
    expect(mocks.playgroundPermissions).toHaveBeenLastCalledWith({
      sessionId: 'session-1',
      read: false,
      write: false,
    });
    wrapper.unmount();
  });

  it('confirms only a displayed exact approval and discards its delayed response after OFF', async () => {
    mocks.playgroundPermissions.mockImplementation(({ read, write }) =>
      Promise.resolve({
        data: {
          playground: payload({
            real_data_read: read,
            real_data_write: read && write,
            action_previews: write ? [approval()] : [],
          }),
        },
      })
    );
    const confirmation = deferred();
    mocks.confirmPlaygroundAction.mockReturnValue(confirmation.promise);
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper.vm.setPermissions(true, true);
    expect(wrapper.text()).toContain('Named deal');
    expect(
      wrapper
        .get('[data-test="playground-action-previews"] details')
        .attributes('open')
    ).toBeUndefined();
    await wrapper
      .get('[data-test="playground-confirm-action"]')
      .trigger('click');
    await flushPromises();
    expect(mocks.confirmPlaygroundAction).toHaveBeenCalledExactlyOnceWith({
      sessionId: 'session-1',
      approval: approval(),
    });
    await wrapper.vm.setPermissions(false, false);
    confirmation.resolve({
      data: {
        success: true,
        playground: payload({
          real_data_read: true,
          real_data_write: true,
          action_previews: [approval()],
        }),
      },
    });
    await flushPromises();
    expect(
      wrapper.find('[data-test="playground-action-previews"]').exists()
    ).toBe(false);
    expect(
      wrapper
        .get('[data-test="playground-real-read"]')
        .attributes('aria-checked')
    ).toBe('false');
    wrapper.unmount();
  });

  it('revokes before waiting for a running turn on reset and ignores its former session reply', async () => {
    const turn = deferred();
    mocks.playground.mockReturnValue(turn.promise);
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper.vm.setPermissions(true, true);
    await send(wrapper);
    const reset = wrapper.vm.resetConversation();
    await flushPromises();
    expect(mocks.playgroundPermissions).toHaveBeenLastCalledWith({
      sessionId: 'session-1',
      read: false,
      write: false,
    });
    turn.resolve({
      data: {
        response: 'Former turn',
        playground: payload({ real_data_read: true, real_data_write: true }),
      },
    });
    await reset;
    await flushPromises();
    expect(wrapper.text()).not.toContain('Former turn');
    expect(mocks.playgroundSession).toHaveBeenLastCalledWith(
      expect.objectContaining({ reset: true })
    );
    expect(
      wrapper
        .get('[data-test="playground-real-read"]')
        .attributes('aria-checked')
    ).toBe('false');
    wrapper.unmount();
  });

  it('does not reset while revocation is unresolved and discards responses for a former workspace', async () => {
    const turn = deferred();
    mocks.playground.mockReturnValue(turn.promise);
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper.vm.setPermissions(true, true);
    mocks.playgroundPermissions.mockRejectedValueOnce(new Error('offline'));
    await wrapper.vm.resetConversation();
    expect(mocks.playgroundSession).toHaveBeenCalledTimes(1);
    await wrapper.vm.setPermissions(false, false);
    await send(wrapper);
    await wrapper.setProps({ accountId: 75 });
    await flushPromises();
    turn.resolve({
      data: {
        response: 'Old workspace',
        playground: payload({ real_data_read: true, real_data_write: true }),
      },
    });
    await flushPromises();
    expect(wrapper.text()).not.toContain('Old workspace');
    expect(
      wrapper
        .get('[data-test="playground-real-read"]')
        .attributes('aria-checked')
    ).toBe('false');
    wrapper.unmount();
  });

  it('shows pending provider confirmation without claiming that the real change has completed', async () => {
    const wrapper = mountPlayground({ realMessages: true });
    await flushPromises();
    await wrapper.vm.setPermissions(true, true);
    mocks.confirmPlaygroundAction.mockResolvedValueOnce({
      data: {
        success: true,
        result: JSON.stringify({
          provider_command_receipt: {
            command: { status: 'awaiting_confirmation' },
          },
        }),
        playground: payload({ real_data_read: true, real_data_write: true }),
      },
    });
    await wrapper.vm.confirmAction(approval());
    await flushPromises();
    expect(wrapper.text()).toContain('CAPTAIN.PLAYGROUND.ACTION_PENDING');
    expect(wrapper.text()).not.toContain('CAPTAIN.PLAYGROUND.ACTION_COMPLETED');
    wrapper.unmount();
  });

  it('switches the test model per request and shows only the parameters it supports', async () => {
    mocks.getModelsForFeature.mockReturnValue([
      {
        id: 'provider/model',
        display_name: 'Profile model',
        supports_temperature: true,
        reasoning_efforts: ['low', 'high'],
      },
      {
        id: 'provider/fast',
        display_name: 'Fast model',
        supports_temperature: false,
        reasoning_efforts: [],
      },
    ]);
    const wrapper = mountPlayground();
    await flushPromises();
    const settings = wrapper.get('[data-test="playground-settings"]');

    expect(settings.find('[data-test="model-temperature"]').exists()).toBe(
      true
    );
    expect(settings.find('[data-test="model-reasoning"]').exists()).toBe(true);
    await settings
      .get('[data-test="model-temperature"] input[type="checkbox"]')
      .setValue(true);
    await settings.get('[data-test="model-reasoning"] select').setValue('high');
    await send(wrapper, 'With the profile model');
    expect(mocks.playground).toHaveBeenLastCalledWith(
      expect.objectContaining({
        testOptions: { model: '', temperature: 1, thinkingEffort: 'high' },
      })
    );

    await settings
      .get('[data-test="model-settings"] select')
      .setValue('provider/fast');
    await flushPromises();
    expect(settings.find('[data-test="model-temperature"]').exists()).toBe(
      false
    );
    expect(settings.find('[data-test="model-reasoning"]').exists()).toBe(false);
    await send(wrapper, 'With the fast model');
    expect(mocks.playground).toHaveBeenLastCalledWith(
      expect.objectContaining({
        testOptions: {
          model: 'provider/fast',
          temperature: null,
          thinkingEffort: '',
        },
      })
    );
    wrapper.unmount();
  });

  it('frames the chat column once and keeps the side panel unframed', async () => {
    mocks.playgroundPermissions.mockImplementation(({ read, write }) =>
      Promise.resolve({
        data: {
          playground: payload({
            real_data_read: read,
            real_data_write: read && write,
            action_previews: write ? [approval()] : [],
          }),
        },
      })
    );
    mocks.playground.mockRejectedValueOnce({
      response: { data: { message: 'Provider down' } },
    });
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper.vm.setPermissions(true, true);
    await send(wrapper);

    const chat = wrapper.get('[data-test="playground-chat"]');
    expect(chat.get('[role="alert"]').text()).toBe('Provider down');
    expect(chat.find('[data-test="playground-action-previews"]').exists()).toBe(
      true
    );
    expect(chat.find('[data-test="playground-message-input"]').exists()).toBe(
      true
    );
    expect(chat.classes()).toEqual(
      expect.arrayContaining(['rounded-xl', 'outline'])
    );
    expect(
      Array.from(chat.element.querySelectorAll('*'))
        .filter(isFramed)
        .map(element => element.outerHTML)
    ).toEqual([]);

    const layout = wrapper.get('[data-test="playground-layout"]');
    expect(Array.from(layout.element.children).filter(isFramed)).toHaveLength(
      1
    );
    const settings = wrapper.get('[data-test="playground-settings"]');
    expect(isFramed(settings.element)).toBe(false);
    expect(settings.text()).toContain('CAPTAIN.AGENT_TABS.CHECK.SIDE_TITLE');
    wrapper.unmount();
  });

  it('preserves additional synthetic catalogs and knowledge fixtures when saving the scenario', async () => {
    const wrapper = mountPlayground();
    await flushPromises();
    await wrapper
      .get('[data-test="playground-scenario-toggle"]')
      .trigger('click');
    const editor = wrapper.findComponent({ name: 'PlaygroundScenarioEditor' });
    const draft = {
      ...scenario(),
      companies: [{ name: 'Synthetic company' }],
      knowledge_documents: [{ name: 'Synthetic guide' }],
    };
    editor.vm.$emit('update:modelValue', draft);
    await flushPromises();
    await wrapper
      .get('[data-test="playground-scenario-save"]')
      .trigger('click');
    await flushPromises();
    expect(mocks.playgroundSession).toHaveBeenLastCalledWith(
      expect.objectContaining({ scenario: draft })
    );
    wrapper.unmount();
  });

  it('does not show the AI typing indicator during initial load or reset, only during an active turn', async () => {
    const initialSession = deferred();
    const initialSettings = deferred();
    const turn = deferred();
    mocks.playgroundSession.mockReturnValueOnce(initialSession.promise);
    mocks.fetch.mockReturnValueOnce(initialSettings.promise);
    mocks.playground.mockReturnValueOnce(turn.promise);

    const wrapper = mountPlayground({ realMessages: true });
    await flushPromises();

    expect(wrapper.find('.animate-bounce').exists()).toBe(false);

    initialSession.resolve({
      data: { playground: payload() },
    });
    initialSettings.resolve();
    await flushPromises();

    expect(wrapper.find('.animate-bounce').exists()).toBe(false);

    await wrapper
      .get('[data-test="playground-message-input"]')
      .setValue('Ping');
    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(wrapper.find('.animate-bounce').exists()).toBe(true);

    turn.resolve({
      data: { response: 'Pong', playground: payload() },
    });
    await flushPromises();

    expect(wrapper.find('.animate-bounce').exists()).toBe(false);

    const resetSession = deferred();
    mocks.playgroundSession.mockReturnValueOnce(resetSession.promise);
    const resetPromise = wrapper.vm.resetConversation();
    await flushPromises();
    expect(wrapper.find('.animate-bounce').exists()).toBe(false);
    resetSession.resolve({
      data: { playground: payload({ session_id: 'reset-1' }) },
    });
    await resetPromise;
    await flushPromises();
    expect(wrapper.find('.animate-bounce').exists()).toBe(false);
    wrapper.unmount();
  });

  it('starts session initialization in parallel with settings and enables input before model catalog finishes', async () => {
    const settingsGate = deferred();
    mocks.fetch.mockReturnValueOnce(settingsGate.promise);
    mocks.playgroundSession.mockResolvedValueOnce({
      data: {
        playground: payload({
          message_history: [
            {
              role: 'assistant',
              content: 'Welcome back',
              agent_id: 4,
              agent_name: 'assistant_4',
              agent_display_name: 'Coordinator Bot',
            },
          ],
        }),
      },
    });

    const wrapper = mountPlayground({ realMessages: true });
    expect(mocks.playgroundSession).toHaveBeenCalledTimes(1);
    expect(mocks.fetch).toHaveBeenCalledTimes(1);

    await flushPromises();

    expect(
      wrapper.get('[data-test="playground-message-input"]').element.disabled
    ).toBe(false);
    expect(
      wrapper.get('[data-test="playground-responding-agent"]').text()
    ).toBe('Coordinator Bot');
    expect(
      wrapper.get('[data-test="model-settings"] select').element.disabled
    ).toBe(true);

    settingsGate.resolve();
    await flushPromises();
    expect(
      wrapper.get('[data-test="model-settings"] select').element.disabled
    ).toBe(false);
    wrapper.unmount();
  });

  it('disables messaging and clears session state when metadata fetch fails', async () => {
    const delayedSession = deferred();
    mocks.playgroundSession.mockReturnValueOnce(delayedSession.promise);
    mocks.uiFlags.fetchError = true;
    const wrapper = mountPlayground();
    await flushPromises();
    delayedSession.resolve({ data: { playground: payload() } });
    await flushPromises();
    expect(
      wrapper.get('[data-test="playground-message-input"]').element.disabled
    ).toBe(true);
    expect(
      wrapper.get('[data-test="playground-real-read"]').element.disabled
    ).toBe(true);
    expect(wrapper.get('[role="alert"]').text()).toBe(
      'CAPTAIN.PLAYGROUND.SESSION_ERROR'
    );
    wrapper.unmount();
  });

  it('pre-warms model metadata on the Sandbox page and opens the Playground with no start agent', async () => {
    mocks.assistants = [
      { id: 15, name: 'Sub Agent', active: true },
      { id: 4, name: 'Other Agent', active: false },
    ];
    mocks.dispatch.mockResolvedValue();

    const wrapper = mount(PlaygroundIndex, {
      global: {
        stubs: {
          PageLayout: {
            props: ['isFetching'],
            template: '<div><slot name="body" /></div>',
          },
          CaptainPaywall: true,
          AssistantPlayground: {
            name: 'AssistantPlayground',
            props: ['assistantId', 'accountId'],
            template:
              '<div data-test="mounted-playground">{{ assistantId }}</div>',
          },
        },
      },
    });
    await flushPromises();

    expect(mocks.dispatch).toHaveBeenCalledWith('captainAssistants/get');
    expect(mocks.fetch).toHaveBeenCalledWith({ clientMetadataOnly: true });
    // No start agent: the page passes no agent id to the Playground.
    expect(wrapper.get('[data-test="mounted-playground"]').text()).toBe('');
    wrapper.unmount();
  });

  it('shows only a sentence on the Sandbox page when the workspace has no agent', async () => {
    mocks.assistants = [];
    mocks.dispatch.mockResolvedValue();

    const wrapper = mount(PlaygroundIndex, {
      global: {
        stubs: {
          PageLayout: {
            props: ['isFetching'],
            template: '<div><slot name="body" /></div>',
          },
          CaptainPaywall: true,
          AssistantPlayground: true,
        },
      },
    });
    await flushPromises();

    expect(wrapper.find('[data-testid="playground-empty"]').exists()).toBe(
      true
    );
    expect(
      wrapper.find('[data-testid="captain-playground-page"]').exists()
    ).toBe(false);
    wrapper.unmount();
  });
});
