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
  props: {
    buttonLabel: {
      type: String,
      default: '',
    },
  },
  emits: ['click'],
  setup(props, { emit, slots }) {
    // Mirrors PageLayout: the header action renders only with a label.
    return () =>
      h('div', [
        props.buttonLabel
          ? h(
              'button',
              {
                'data-testid': 'page-save',
                onClick: () => emit('click'),
              },
              props.buttonLabel
            )
          : null,
        slots.body?.(),
      ]);
  },
});

const AssistantBasicSettingsFormStub = defineComponent({
  name: 'AssistantBasicSettingsForm',
  props: {
    descriptionMaxLength: {
      type: Number,
      default: undefined,
    },
    descriptionMinHeight: {
      type: String,
      default: undefined,
    },
    descriptionInitialHeight: {
      type: Number,
      default: undefined,
    },
  },
  setup(props, { expose }) {
    expose({
      buildPayload: vi.fn(async () => ({
        assistant: { description: 'Updated instruction' },
      })),
    });

    return () =>
      h(
        'div',
        {
          'data-max-length': props.descriptionMaxLength,
          'data-min-height': props.descriptionMinHeight,
          'data-initial-height': props.descriptionInitialHeight,
        },
        'basic-form'
      );
  },
});

const AssistantRulesManagerStub = defineComponent({
  name: 'AssistantRulesManager',
  setup(_props, { expose }) {
    expose({
      buildPayload: rulesBuildPayloadMock,
    });

    return () => h('div', { 'data-testid': 'rules-manager' }, 'rules-manager');
  },
});

const AssistantScenariosManagerStub = defineComponent({
  name: 'AssistantScenariosManager',
  props: {
    showHeader: {
      type: Boolean,
      default: true,
    },
  },
  setup(props) {
    return () =>
      h(
        'div',
        {
          'data-testid': 'scenarios-manager',
          'data-show-header': String(props.showHeader),
        },
        'scenarios-manager'
      );
  },
});

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({
    params: { accountId: '7', assistantId: '58' },
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => useAlertMock(...args),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({
    dispatch: dispatchMock,
    getters: {
      'captainAssistants/getRecord': () => assistantRecord,
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
    default: AssistantScenariosManagerStub,
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

  it('uses the assistant loaded by the route guard without another show request', () => {
    const wrapper = buildWrapper();

    expect(wrapper.text()).toContain('basic-form');
    expect(dispatchMock).not.toHaveBeenCalledWith(
      'captainAssistants/show',
      58
    );
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

  it('renders the real prompts surface with a tall instruction editor', () => {
    const wrapper = buildWrapper();
    const promptForm = wrapper.findComponent({
      name: 'AssistantBasicSettingsForm',
    });

    expect(promptForm.props('descriptionMaxLength')).toBe(20000);
    expect(promptForm.props('descriptionInitialHeight')).toBe(420);
    expect(promptForm.props('descriptionMinHeight')).toBe('26rem');
  });

  it('keeps the instructions editor, rules and the prompt inspector of an AI agent', () => {
    const wrapper = buildWrapper();

    expect(
      wrapper.findComponent({ name: 'AssistantBasicSettingsForm' }).exists()
    ).toBe(true);
    expect(wrapper.find('[data-testid="rules-manager"]').exists()).toBe(true);
    expect(wrapper.findComponent({ name: 'PromptInspector' }).exists()).toBe(
      true
    );
    expect(wrapper.find('[data-testid="page-save"]').exists()).toBe(true);
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
