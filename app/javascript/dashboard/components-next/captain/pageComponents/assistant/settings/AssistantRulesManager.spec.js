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
    template: '<div><slot /></div>',
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

const addNewRulesDialogStub = {
  name: 'AddNewRulesDialog',
  emits: ['add'],
  template: `
    <button
      data-testid="add-rule"
      @click="$emit('add', {
        type: 'guardrail',
        group: 'Restrictions',
        content: 'Never expose internal secrets.',
        enabled: true,
      })"
    >
      Add
    </button>
  `,
};

const buildWrapper = props =>
  shallowMount(AssistantRulesManager, {
    props,
    global: {
      stubs: {
        AddNewRulesDialog: addNewRulesDialogStub,
        BulkSelectBar: bulkSelectBarStub,
        Input: true,
        RuleCard: true,
        SettingsHeader: true,
        SuggestedRules: suggestedRulesStub,
      },
    },
  });

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

  it('preserves the existing assistant config when saving rules', async () => {
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

    await wrapper.get('[data-testid="add-rule"]').trigger('click');
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/update', {
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
        rules: [
          expect.objectContaining({
            type: 'guardrail',
            group: 'Restrictions',
            content: 'Never expose internal secrets.',
            enabled: true,
          }),
        ],
      },
    });
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
          rules: [],
        },
      },
    });

    expect(wrapper.text()).toContain(
      'CAPTAIN.ASSISTANTS.RULES.GROUPS.CONVERSATION'
    );
  });
});
