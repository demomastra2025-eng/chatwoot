/* eslint-disable vue/one-component-per-file */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, reactive } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const updateMock = vi.fn();
const dispatchMock = vi.fn();
const useAlertMock = vi.fn();
const assistantRecord = reactive({
  id: 58,
  config: { follow_up_settings: { enabled: false, steps: [] } },
});

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { assistantId: '58' } }),
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
}));

vi.mock('dashboard/api/captain/assistant', () => ({
  default: { update: (...args) => updateMock(...args) },
}));

vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: defineComponent({
    name: 'PageLayout',
    setup(_props, { slots }) {
      return () => h('div', slots.body?.());
    },
  }),
}));

vi.mock(
  'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue',
  () => ({
    default: defineComponent({ name: 'SettingsHeader', template: '<div />' }),
  })
);

vi.mock('dashboard/components-next/switch/Switch.vue', () => ({
  default: defineComponent({
    name: 'SwitchStub',
    props: { modelValue: Boolean },
    emits: ['update:modelValue'],
    setup(props, { emit }) {
      return () =>
        h('input', {
          type: 'checkbox',
          'data-testid': 'follow-up-switch',
          checked: props.modelValue,
          onChange: event => emit('update:modelValue', event.target.checked),
        });
    },
  }),
}));

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: defineComponent({
    name: 'ButtonStub',
    inheritAttrs: false,
    props: { label: { type: String, default: '' }, isLoading: Boolean },
    emits: ['click'],
    setup(props, { attrs, emit }) {
      return () =>
        h(
          'button',
          { ...attrs, disabled: props.isLoading, onClick: () => emit('click') },
          props.label
        );
    },
  }),
}));

const { default: FollowUpsIndex } = await import('./Index.vue');
const mountComponent = () => mount(FollowUpsIndex);

const clickSave = async wrapper => {
  await wrapper.get('[data-testid="follow-up-save"]').trigger('click');
  await flushPromises();
};

describe('Captain follow-ups page', () => {
  beforeEach(() => {
    assistantRecord.config = {
      follow_up_settings: { enabled: false, steps: [] },
    };
    updateMock.mockReset();
    updateMock.mockResolvedValue({});
    dispatchMock.mockReset();
    dispatchMock.mockResolvedValue({});
    useAlertMock.mockReset();
  });

  it('disables the prompt and steps while follow-ups are off but keeps save available', () => {
    const wrapper = mountComponent();

    expect(
      wrapper.get('[data-testid="follow-up-editor"]').attributes()
    ).toHaveProperty('disabled');
    expect(wrapper.get('#follow-up-prompt').element.disabled).toBe(true);
    expect(wrapper.get('[data-testid="follow-up-save"]').element.disabled).toBe(
      false
    );
  });

  it('keeps legacy message-only steps in static mode', async () => {
    assistantRecord.config = {
      follow_up_settings: {
        enabled: true,
        steps: [{ delay_seconds: 3600, message: 'Legacy reminder' }],
      },
    };
    const wrapper = mountComponent();

    expect(wrapper.get('[data-testid="follow-up-mode"]').element.value).toBe(
      'static'
    );
    expect(wrapper.get('[data-testid="follow-up-message"]').element.value).toBe(
      'Legacy reminder'
    );

    await clickSave(wrapper);

    expect(updateMock).toHaveBeenCalledWith(58, {
      config: {
        follow_up_settings: {
          enabled: true,
          prompt: 'CAPTAIN.ASSISTANTS.FOLLOW_UPS.DEFAULT_PROMPT',
          steps: [
            {
              delay_seconds: 3600,
              mode: 'static',
              message: 'Legacy reminder',
            },
          ],
        },
      },
    });
  });

  it('saves a global prompt and per-step objective for AI generation', async () => {
    assistantRecord.config = {
      follow_up_settings: {
        enabled: true,
        prompt: 'Continue naturally.',
        steps: [
          {
            delay_seconds: 10_800,
            mode: 'ai',
            objective: 'Offer one clear next action',
          },
        ],
      },
    };
    const wrapper = mountComponent();

    await wrapper
      .get('#follow-up-prompt')
      .setValue('Do not pressure the customer.');
    await wrapper
      .get('[data-testid="follow-up-objective"]')
      .setValue('Ask whether more information is needed');
    await clickSave(wrapper);

    expect(updateMock).toHaveBeenCalledWith(58, {
      config: {
        follow_up_settings: {
          enabled: true,
          prompt: 'Do not pressure the customer.',
          steps: [
            {
              delay_seconds: 10_800,
              mode: 'ai',
              objective: 'Ask whether more information is needed',
            },
          ],
        },
      },
    });
  });

  it('shows one compact step editor at a time', async () => {
    assistantRecord.config = {
      follow_up_settings: {
        enabled: true,
        steps: [
          { delay_seconds: 3600, mode: 'ai', objective: 'First touch' },
          { delay_seconds: 7200, mode: 'ai', objective: 'Second touch' },
        ],
      },
    };
    const wrapper = mountComponent();
    const toggles = wrapper.findAll('[data-testid="follow-up-step-toggle"]');

    expect(toggles).toHaveLength(2);
    expect(toggles[0].attributes('aria-expanded')).toBe('true');
    expect(toggles[1].attributes('aria-expanded')).toBe('false');
    expect(
      wrapper.findAll('[data-testid="follow-up-step-details"]')
    ).toHaveLength(1);

    await toggles[1].trigger('click');

    expect(toggles[0].attributes('aria-expanded')).toBe('false');
    expect(toggles[1].attributes('aria-expanded')).toBe('true');
    expect(
      wrapper.findAll('[data-testid="follow-up-step-details"]')
    ).toHaveLength(1);
  });

  it('preserves an unsaved prompt during a background assistant refresh', async () => {
    assistantRecord.config = {
      follow_up_settings: {
        enabled: true,
        prompt: 'Saved prompt',
        steps: [{ delay_seconds: 3600, mode: 'ai', objective: 'Follow up' }],
      },
    };
    const wrapper = mountComponent();
    const prompt = wrapper.get('#follow-up-prompt');
    await prompt.setValue('Unsaved prompt');

    assistantRecord.config = {
      follow_up_settings: {
        enabled: true,
        prompt: 'Background prompt',
        steps: [{ delay_seconds: 3600, mode: 'ai', objective: 'Follow up' }],
      },
    };
    await flushPromises();

    expect(prompt.element.value).toBe('Unsaved prompt');
  });

  it('preserves edits made while an earlier draft is being saved', async () => {
    assistantRecord.config = {
      follow_up_settings: {
        enabled: true,
        prompt: 'Saved prompt',
        steps: [{ delay_seconds: 3600, mode: 'ai', objective: 'Follow up' }],
      },
    };
    let resolveUpdate;
    updateMock.mockReturnValue(
      new Promise(resolve => {
        resolveUpdate = resolve;
      })
    );
    const wrapper = mountComponent();
    const prompt = wrapper.get('#follow-up-prompt');
    await prompt.setValue('Submitted draft');
    await wrapper.get('[data-testid="follow-up-save"]').trigger('click');
    await prompt.setValue('Edited during save');

    resolveUpdate({});
    await flushPromises();
    assistantRecord.config = {
      follow_up_settings: {
        enabled: true,
        prompt: 'Submitted draft',
        steps: [{ delay_seconds: 3600, mode: 'ai', objective: 'Follow up' }],
      },
    };
    await flushPromises();

    expect(prompt.element.value).toBe('Edited during save');
  });
});
