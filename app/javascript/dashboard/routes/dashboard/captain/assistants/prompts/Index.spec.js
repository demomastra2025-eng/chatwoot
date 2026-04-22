import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const dispatchMock = vi.fn();
const useAlertMock = vi.fn();
const rulesBuildPayloadMock = vi.fn();
const assistantRecord = {
  id: 58,
  usage_mode: 'external_agent',
  config: {
    rules: [
      {
        id: 'stay_within_scope',
        type: 'system',
        group: 'Strict rules',
        content: 'Stay within your configured scope and instructions.',
        enabled: true,
        editable: true,
        deletable: false,
      },
    ],
  },
};

const PageLayoutStub = defineComponent({
  name: 'PageLayout',
  emits: ['click'],
  setup(_props, { emit, slots }) {
    return () =>
      h('div', [
        h(
          'button',
          {
            'data-testid': 'page-save',
            onClick: () => emit('click'),
          },
          'Save'
        ),
        slots.body?.(),
      ]);
  },
});

const AssistantBasicSettingsFormStub = defineComponent({
  name: 'AssistantBasicSettingsForm',
  setup(_props, { expose }) {
    expose({
      buildPayload: vi.fn(async () => ({
        assistant: { description: 'Updated instruction' },
      })),
    });

    return () => h('div', 'basic-form');
  },
});

const AssistantRulesManagerStub = defineComponent({
  name: 'AssistantRulesManager',
  setup(_props, { expose }) {
    expose({
      buildPayload: rulesBuildPayloadMock,
    });

    return () => h('div', 'rules-manager');
  },
});

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({
    params: { assistantId: '58' },
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => useAlertMock(...args),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({
    dispatch: dispatchMock,
    getters: {
      'captainAssistants/getRecord': () => () => assistantRecord,
    },
  }),
  useMapGetter: key => {
    if (key === 'captainAssistants/getUIFlags') {
      return ref({ fetchingItem: false });
    }

    return ref({});
  },
}));

vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: PageLayoutStub,
}));
vi.mock(
  'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantBasicSettingsForm.vue',
  () => ({ default: AssistantBasicSettingsFormStub })
);
vi.mock(
  'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantRulesManager.vue',
  () => ({ default: AssistantRulesManagerStub })
);
vi.mock(
  'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantScenariosManager.vue',
  () => ({
    default: defineComponent({
      name: 'AssistantScenariosManager',
      template: '<div />',
    }),
  })
);
vi.mock(
  'dashboard/components-next/captain/pageComponents/assistant/PromptInspector.vue',
  () => ({
    default: defineComponent({ name: 'PromptInspector', template: '<div />' }),
  })
);
vi.mock(
  'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue',
  () => ({
    default: defineComponent({ name: 'SettingsHeader', template: '<div />' }),
  })
);
vi.mock('dashboard/components-next/tabbar/TabBar.vue', () => ({
  default: defineComponent({ name: 'TabBar', template: '<div />' }),
}));

const { default: PromptsIndex } = await import('./Index.vue');

const buildWrapper = () => mount(PromptsIndex);

describe('Captain prompts page', () => {
  beforeEach(() => {
    dispatchMock.mockReset();
    dispatchMock.mockResolvedValue({});
    useAlertMock.mockReset();
    rulesBuildPayloadMock.mockReset();
    rulesBuildPayloadMock.mockImplementation(() => ({
      assistant: {
        config: {
          rules: [
            {
              id: 'stay_within_scope',
              type: 'system',
              group: 'Strict rules',
              content: 'Stay within your configured scope and instructions.',
              enabled: true,
              editable: true,
              deletable: false,
            },
            {
              id: 'reply_short',
              type: 'response_guideline',
              group: 'Conversation flow',
              content: 'Reply with a short direct answer first.',
              enabled: true,
              editable: true,
              deletable: true,
            },
          ],
        },
      },
    }));
  });

  it('saves rules together with the instruction when the rules tab is active', async () => {
    const wrapper = buildWrapper();

    await wrapper.get('[data-testid="page-save"]').trigger('click');
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/update', {
      id: 58,
      description: 'Updated instruction',
      config: {
        rules: [
          {
            id: 'stay_within_scope',
            type: 'system',
            group: 'Strict rules',
            content: 'Stay within your configured scope and instructions.',
            enabled: true,
            editable: true,
            deletable: false,
          },
          {
            id: 'reply_short',
            type: 'response_guideline',
            group: 'Conversation flow',
            content: 'Reply with a short direct answer first.',
            enabled: true,
            editable: true,
            deletable: true,
          },
        ],
      },
    });
  });

  it('shows the rules validation error and skips update when page-level save cannot build the rules payload', async () => {
    rulesBuildPayloadMock.mockImplementation(() => {
      throw new Error('CAPTAIN.ASSISTANTS.RULES.MALFORMED_RULES_ERROR');
    });

    const wrapper = buildWrapper();

    await wrapper.get('[data-testid="page-save"]').trigger('click');
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
