import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const dispatchMock = vi.fn();
const useAlertMock = vi.fn();
const buildPayloadMock = vi.fn();
const assistantRecord = {
  id: 58,
  usage_mode: 'external_agent',
  description: 'Own instructions',
  config: {},
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
      buildPayload: buildPayloadMock,
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
    buildPayloadMock.mockReset();
    buildPayloadMock.mockResolvedValue({
      assistant: { description: 'Updated instruction' },
    });
    assistantRecord.description = 'Own instructions';
  });

  it('uses the assistant loaded by the route guard without another show request', () => {
    const wrapper = buildWrapper();
    expect(wrapper.text()).toContain('basic-form');
    expect(dispatchMock).not.toHaveBeenCalledWith('captainAssistants/show', 58);
  });

  it('saves the main instructions without separate rules', async () => {
    const wrapper = buildWrapper();
    await wrapper.get('[data-testid="page-save"]').trigger('click');
    await flushPromises();
    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/update', {
      id: 58,
      description: 'Updated instruction',
    });
    expect(useAlertMock).toHaveBeenCalledWith(
      'CAPTAIN.ASSISTANTS.EDIT.SUCCESS_MESSAGE'
    );
  });

  it('keeps the tall prompt editor and compiled preview available', () => {
    const wrapper = buildWrapper();
    const form = wrapper.findComponent({ name: 'AssistantBasicSettingsForm' });
    expect(form.props('descriptionMaxLength')).toBe(20000);
    expect(form.props('descriptionInitialHeight')).toBe(420);
    expect(form.props('descriptionMinHeight')).toBe('26rem');
    expect(wrapper.findComponent({ name: 'PromptInspector' }).exists()).toBe(
      true
    );
    expect(
      wrapper.findComponent({ name: 'AssistantRulesManager' }).exists()
    ).toBe(false);
    expect(wrapper.find('[data-testid="page-save"]').exists()).toBe(true);
  });

  it('allows editing an existing prompt enlarged by preserved legacy rules', () => {
    assistantRecord.description = 'a'.repeat(24000);
    const wrapper = buildWrapper();
    expect(
      wrapper
        .findComponent({ name: 'AssistantBasicSettingsForm' })
        .props('descriptionMaxLength')
    ).toBe(24000);
  });

  it('shows prompt validation errors and skips the update', async () => {
    buildPayloadMock.mockRejectedValue(new Error('Prompt validation failed'));
    const wrapper = buildWrapper();
    await wrapper.get('[data-testid="page-save"]').trigger('click');
    await flushPromises();
    expect(dispatchMock).not.toHaveBeenCalledWith(
      'captainAssistants/update',
      expect.anything()
    );
    expect(useAlertMock).toHaveBeenCalledWith('Prompt validation failed');
  });
});
