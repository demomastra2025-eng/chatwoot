import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import AssistantPlayground from './AssistantPlayground.vue';

const mocks = vi.hoisted(() => ({
  playground: vi.fn(),
  playgroundSession: vi.fn(),
  playgroundPermissions: vi.fn(),
  confirmPlaygroundAction: vi.fn(),
  show: vi.fn(),
  fetch: vi.fn(),
  getModelsForFeature: vi.fn(),
  getSelectedModelForFeature: vi.fn(),
  uiFlags: { fetchError: false },
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/api/captain/assistant', () => ({ default: mocks }));
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
    props: { assistantId: 4, accountId: 74 },
    global: {
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

beforeEach(() => {
  Object.values(mocks).forEach(value => value?.mockReset?.());
  mocks.uiFlags.fetchError = false;
  mocks.fetch.mockResolvedValue();
  mocks.show.mockResolvedValue({
    data: {
      id: 4,
      usage_mode: 'external_agent',
      config: {},
      playground_model: {
        id: 'provider/model',
        supports_temperature: true,
        reasoning_efforts: ['low', 'high'],
      },
    },
  });
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

  it('keeps all model controls behind the gear and write access hidden/off until reading is enabled', async () => {
    const wrapper = mountPlayground();
    await flushPromises();
    expect(wrapper.find('select').exists()).toBe(false);
    expect(wrapper.find('[data-test="playground-real-write"]').exists()).toBe(
      false
    );
    expect(
      wrapper.get('[data-test="playground-real-read"]').element.checked
    ).toBe(false);
    await wrapper.get('[data-test="model-settings-toggle"]').trigger('click');
    expect(wrapper.find('[data-test="model-temperature"]').exists()).toBe(true);
    await wrapper.get('[data-test="playground-real-read"]').setValue(true);
    await flushPromises();
    expect(
      wrapper.get('[data-test="playground-real-write"]').element.checked
    ).toBe(false);
    await wrapper.get('[data-test="playground-real-write"]').setValue(true);
    await flushPromises();
    expect(
      wrapper.find('[data-test="playground-write-warning"]').exists()
    ).toBe(true);
    expect(mocks.playgroundPermissions).toHaveBeenLastCalledWith({
      assistantId: 4,
      sessionId: 'session-1',
      read: true,
      write: true,
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
      wrapper.get('[data-test="playground-real-read"]').element.checked
    ).toBe(false);
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
      assistantId: 4,
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
      assistantId: 4,
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
      wrapper.get('[data-test="playground-real-read"]').element.checked
    ).toBe(false);
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
      assistantId: 4,
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
      wrapper.get('[data-test="playground-real-read"]').element.checked
    ).toBe(false);
    wrapper.unmount();
  });

  it('does not reset while revocation is unresolved and discards responses for a former assistant', async () => {
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
    await wrapper.setProps({ assistantId: 5 });
    await flushPromises();
    turn.resolve({
      data: {
        response: 'Old assistant',
        playground: payload({ real_data_read: true, real_data_write: true }),
      },
    });
    await flushPromises();
    expect(wrapper.text()).not.toContain('Old assistant');
    expect(
      wrapper.get('[data-test="playground-real-read"]').element.checked
    ).toBe(false);
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
});
