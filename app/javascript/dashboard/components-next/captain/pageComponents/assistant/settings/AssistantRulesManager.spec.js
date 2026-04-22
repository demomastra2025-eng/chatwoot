import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { ref } from 'vue';

import AssistantRulesManager from './AssistantRulesManager.vue';

const dispatchMock = vi.fn();
const updateUISettingsMock = vi.fn();
const useAlertMock = vi.fn();
const useStoreMock = vi.fn();
const useUISettingsMock = vi.fn();

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => useAlertMock(...args),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: (...args) => useStoreMock(...args),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: (...args) => useUISettingsMock(...args),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('vuedraggable', () => ({
  default: {
    name: 'Draggable',
    props: ['modelValue'],
    template: '<div />',
  },
}));

const bulkSelectBarStub = {
  name: 'BulkSelectBar',
  template: `
    <div>
      <slot name="default-actions" />
      <slot />
    </div>
  `,
};

const suggestedRulesStub = {
  name: 'SuggestedRules',
  props: ['items'],
  template: `
    <div data-testid="suggested-rules">
      <slot :item="items[0]" />
    </div>
  `,
};

const buttonStub = {
  name: 'Button',
  props: ['label'],
  emits: ['click'],
  template: `
    <button :data-label="label" @click="$emit('click')">
      {{ label }}
    </button>
  `,
};

const buildWrapper = props =>
  shallowMount(AssistantRulesManager, {
    props,
    global: {
      stubs: {
        BulkSelectBar: bulkSelectBarStub,
        Button: buttonStub,
        InlineRuleComposer: true,
        Input: true,
        RuleCard: true,
        SettingsHeader: true,
        SuggestedRules: suggestedRulesStub,
      },
    },
  });

const systemRules = [
  {
    id: 'stay_within_scope',
    type: 'system',
    group: 'Strict rules',
    content: 'Stay within your configured scope and instructions.',
    enabled: true,
    editable: false,
  },
];

describe('AssistantRulesManager', () => {
  beforeEach(() => {
    dispatchMock.mockReset();
    dispatchMock.mockResolvedValue({});
    useAlertMock.mockReset();
    updateUISettingsMock.mockReset();

    useStoreMock.mockReturnValue({
      dispatch: dispatchMock,
    });
    useUISettingsMock.mockReturnValue({
      uiSettings: ref({
        show_assistant_rules_suggestions: false,
      }),
      updateUISettings: updateUISettingsMock,
    });
  });

  it('preserves the existing assistant config envelope when saving rules', async () => {
    const wrapper = buildWrapper({
      assistantId: 42,
      assistant: {
        config: {
          context_access: { contact: true },
          tool_access: {
            agent: {
              enabled: true,
              tool_ids: ['handoff'],
            },
          },
          temperature: 0.4,
          history_message_limit: 12,
          rules: [],
        },
      },
    });

    await wrapper.vm.saveRules([
      {
        id: 'assistant_rule_guardrail',
        type: 'guardrail',
        group: 'Restrictions',
        content: 'Never expose internal secrets.',
        enabled: true,
      },
    ]);
    await flushPromises();

    const updateCall = dispatchMock.mock.calls.find(
      ([action]) => action === 'captainAssistants/update'
    );

    expect(updateCall?.[1]).toMatchObject({
      id: 42,
      config: {
        context_access: { contact: true },
        tool_access: {
          agent: {
            enabled: true,
            tool_ids: ['handoff'],
          },
        },
        temperature: 0.4,
        history_message_limit: 12,
      },
    });
    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/show', 42);
  });

  it('renders localized rule group labels in suggested rules', () => {
    useUISettingsMock.mockReturnValue({
      uiSettings: ref({
        show_assistant_rules_suggestions: true,
      }),
      updateUISettings: updateUISettingsMock,
    });

    const wrapper = buildWrapper({
      assistantId: 42,
      assistant: {
        config: {
          rules: systemRules,
        },
      },
    });

    expect(wrapper.text()).toContain(
      'CAPTAIN.ASSISTANTS.RULES.GROUPS.CONVERSATION'
    );
  });

  it('preserves system rules when saving without custom entries', async () => {
    const wrapper = buildWrapper({
      assistantId: 42,
      assistant: {
        config: {
          rules: systemRules,
        },
      },
    });
    await wrapper.vm.saveRules(systemRules);
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/update', {
      id: 42,
      config: expect.objectContaining({
        rules: [
          expect.objectContaining({
            id: 'stay_within_scope',
            type: 'system',
            content: 'Stay within your configured scope and instructions.',
          }),
        ],
      }),
    });
  });

  it('keeps malformed rules visible and blocks unrelated saves until they are resolved', async () => {
    const wrapper = buildWrapper({
      assistantId: 42,
      assistant: {
        config: {
          rules: [
            ...systemRules,
            {
              id: 'assistant_rule_invalid',
              type: 'guardrail',
              group: 'Restrictions',
              content: '   ',
              enabled: true,
            },
          ],
        },
      },
    });
    dispatchMock.mockClear();
    await wrapper.vm.saveRules([
      ...systemRules,
      {
        id: 'assistant_rule_invalid',
        type: 'guardrail',
        group: 'Restrictions',
        content: '   ',
        enabled: true,
      },
    ]);
    await flushPromises();

    expect(dispatchMock).not.toHaveBeenCalledWith(
      'captainAssistants/update',
      expect.anything()
    );
    expect(useAlertMock).toHaveBeenCalledWith(
      'CAPTAIN.ASSISTANTS.RULES.MALFORMED_RULES_ERROR'
    );
  });
});
