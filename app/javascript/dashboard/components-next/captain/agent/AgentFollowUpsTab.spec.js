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
  useI18n: () => ({ t: key => key, te: () => true }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => useAlertMock(...args),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: dispatchMock }),
}));

vi.mock('dashboard/api/captain/assistant', () => ({
  default: { update: (...args) => updateMock(...args) },
}));

vi.mock('dashboard/components-next/Settings/SettingsToggleSection.vue', () => ({
  default: defineComponent({
    name: 'SettingsToggleSectionStub',
    props: {
      modelValue: Boolean,
      disabled: Boolean,
    },
    emits: ['update:modelValue'],
    setup(props, { emit, slots }) {
      return () =>
        h('div', [
          h('input', {
            type: 'checkbox',
            'data-testid': 'follow-up-switch',
            checked: props.modelValue,
            disabled: props.disabled,
            onChange: event => emit('update:modelValue', event.target.checked),
          }),
          slots.editor?.(),
        ]);
    },
  }),
}));

vi.mock('dashboard/components-next/CardLayout.vue', () => ({
  default: defineComponent({
    name: 'CardLayoutStub',
    setup(_props, { slots }) {
      return () => h('div', slots.default?.());
    },
  }),
}));

vi.mock('dashboard/components-next/textarea/TextArea.vue', () => ({
  default: defineComponent({
    name: 'TextAreaStub',
    props: {
      modelValue: { type: String, default: '' },
      id: { type: String, default: '' },
      maxLength: { type: Number, default: 200 },
      disabled: Boolean,
    },
    emits: ['update:modelValue'],
    setup(props, { emit }) {
      return () =>
        h('textarea', {
          id: props.id,
          value: props.modelValue,
          maxlength: props.maxLength,
          disabled: props.disabled,
          onInput: event => emit('update:modelValue', event.target.value),
        });
    },
  }),
}));

vi.mock('dashboard/components-next/input/Input.vue', () => ({
  default: defineComponent({
    name: 'InputStub',
    props: {
      modelValue: { type: [String, Number], default: '' },
      id: { type: String, default: '' },
      type: { type: String, default: 'text' },
      disabled: Boolean,
    },
    emits: ['update:modelValue'],
    setup(props, { emit }) {
      return () =>
        h('input', {
          id: props.id,
          type: props.type,
          value: props.modelValue,
          disabled: props.disabled,
          onInput: event => {
            const { value } = event.target;
            emit(
              'update:modelValue',
              props.type === 'number' && value !== '' ? Number(value) : value
            );
          },
        });
    },
  }),
}));

vi.mock('dashboard/components-next/select/Select.vue', () => ({
  default: defineComponent({
    name: 'SelectStub',
    props: {
      modelValue: { type: [String, Number], default: '' },
      id: { type: String, default: '' },
      options: { type: Array, default: () => [] },
      disabled: Boolean,
    },
    emits: ['update:modelValue'],
    setup(props, { emit }) {
      return () =>
        h(
          'select',
          {
            id: props.id,
            value: props.modelValue,
            disabled: props.disabled,
            onChange: event => emit('update:modelValue', event.target.value),
          },
          props.options.map(option =>
            h('option', { value: option.value }, option.label)
          )
        );
    },
  }),
}));

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: defineComponent({
    name: 'ButtonStub',
    inheritAttrs: false,
    props: {
      label: { type: String, default: '' },
      isLoading: Boolean,
      disabled: Boolean,
    },
    emits: ['click'],
    setup(props, { attrs, emit }) {
      return () =>
        h(
          'button',
          {
            ...attrs,
            disabled: props.disabled || props.isLoading,
            onClick: () => emit('click'),
          },
          props.label
        );
    },
  }),
}));

const { default: AgentFollowUpsTab } = await import('./AgentFollowUpsTab.vue');

const mountTab = ({ canEdit = true } = {}) =>
  mount(AgentFollowUpsTab, {
    props: { assistant: assistantRecord, canEdit },
  });

const setSettings = followUpSettings => {
  assistantRecord.config = { follow_up_settings: followUpSettings };
};

const saveButton = wrapper => wrapper.get('[data-testid="follow-up-save"]');

const clickSave = async wrapper => {
  await saveButton(wrapper).trigger('click');
  await flushPromises();
};

describe('AgentFollowUpsTab', () => {
  beforeEach(() => {
    setSettings({ enabled: false, steps: [] });
    updateMock.mockReset();
    updateMock.mockResolvedValue({ data: { id: 58 } });
    dispatchMock.mockReset();
    dispatchMock.mockResolvedValue({ id: 58, name: 'Refreshed' });
    useAlertMock.mockReset();
  });

  it('disables the prompt and steps while follow-ups are off', async () => {
    const wrapper = mountTab();

    expect(wrapper.get('#follow-up-prompt').element.disabled).toBe(true);
    expect(
      wrapper.get('[data-testid="follow-up-add-step"]').element.disabled
    ).toBe(true);
    wrapper
      .findAll('[data-testid="follow-up-step-toggle"]')
      .forEach(toggle => expect(toggle.element.disabled).toBe(true));
    expect(
      wrapper.findAll('[data-testid="follow-up-step-details"]')
    ).toHaveLength(0);
    expect(
      wrapper.get('[data-testid="follow-up-switch"]').element.disabled
    ).toBe(false);
    expect(saveButton(wrapper).element.disabled).toBe(true);

    await wrapper.get('[data-testid="follow-up-switch"]').setValue(true);

    expect(wrapper.get('#follow-up-prompt').element.disabled).toBe(false);
    expect(
      wrapper.get('[data-testid="follow-up-add-step"]').element.disabled
    ).toBe(false);
    expect(
      wrapper.findAll('[data-testid="follow-up-step-details"]')
    ).toHaveLength(1);
    expect(saveButton(wrapper).element.disabled).toBe(false);
  });

  it('is read-only without the right to edit but still lets a step be viewed', async () => {
    setSettings({
      enabled: true,
      prompt: 'Saved prompt',
      steps: [
        { delay_seconds: 3600, mode: 'ai', objective: 'First touch' },
        { delay_seconds: 7200, mode: 'ai', objective: 'Second touch' },
      ],
    });
    const wrapper = mountTab({ canEdit: false });

    expect(
      wrapper.get('[data-testid="follow-up-switch"]').element.disabled
    ).toBe(true);
    expect(wrapper.get('#follow-up-prompt').element.disabled).toBe(true);
    expect(wrapper.get('[data-testid="follow-up-mode"]').element.disabled).toBe(
      true
    );
    expect(
      wrapper.get('[data-testid="follow-up-objective"]').element.disabled
    ).toBe(true);
    expect(
      wrapper.get('[data-testid="follow-up-add-step"]').element.disabled
    ).toBe(true);
    wrapper
      .findAll('[data-testid="follow-up-step-remove"]')
      .forEach(button => expect(button.element.disabled).toBe(true));
    expect(wrapper.find('[data-testid="follow-up-save"]').exists()).toBe(false);

    const toggles = wrapper.findAll('[data-testid="follow-up-step-toggle"]');
    expect(toggles[1].element.disabled).toBe(false);
    await toggles[1].trigger('click');
    expect(toggles[1].attributes('aria-expanded')).toBe('true');
    expect(await wrapper.vm.save()).toBe(false);
    expect(updateMock).not.toHaveBeenCalled();
  });

  it('keeps legacy message-only steps in static mode', async () => {
    setSettings({
      enabled: true,
      steps: [{ delay_seconds: 3600, message: 'Legacy reminder' }],
    });
    const wrapper = mountTab();

    expect(wrapper.get('[data-testid="follow-up-mode"]').element.value).toBe(
      'static'
    );
    expect(wrapper.get('[data-testid="follow-up-message"]').element.value).toBe(
      'Legacy reminder'
    );

    await wrapper
      .get('[data-testid="follow-up-message"]')
      .setValue('Updated reminder');
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
              message: 'Updated reminder',
            },
          ],
        },
      },
    });
  });

  it('saves only the follow-up settings, refreshes the agent and reports it', async () => {
    setSettings({
      enabled: true,
      prompt: 'Continue naturally.',
      steps: [
        {
          delay_seconds: 10_800,
          mode: 'ai',
          objective: 'Offer one clear next action',
        },
      ],
    });
    const wrapper = mountTab();

    await wrapper
      .get('#follow-up-prompt')
      .setValue('Do not pressure the customer.');
    await wrapper
      .get('[data-testid="follow-up-objective"]')
      .setValue('Ask whether more information is needed');
    await clickSave(wrapper);

    expect(updateMock).toHaveBeenCalledExactlyOnceWith(58, {
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
    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/show', 58);
    expect(wrapper.emitted('saved')).toEqual([[{ id: 58, name: 'Refreshed' }]]);
    expect(useAlertMock).toHaveBeenCalledWith(
      'CAPTAIN.ASSISTANTS.EDIT.SUCCESS_MESSAGE'
    );
  });

  it('adds and removes steps', async () => {
    setSettings({
      enabled: true,
      prompt: 'Saved prompt',
      steps: [{ delay_seconds: 3600, mode: 'ai', objective: 'First touch' }],
    });
    const wrapper = mountTab();

    expect(wrapper.findAll('[data-testid="follow-up-step"]')).toHaveLength(1);
    expect(wrapper.find('[data-testid="follow-up-step-remove"]').exists()).toBe(
      false
    );

    await wrapper.get('[data-testid="follow-up-add-step"]').trigger('click');

    const toggles = wrapper.findAll('[data-testid="follow-up-step-toggle"]');
    expect(toggles).toHaveLength(2);
    expect(toggles[1].attributes('aria-expanded')).toBe('true');
    expect(
      wrapper.findAll('[data-testid="follow-up-step-remove"]')
    ).toHaveLength(2);

    await wrapper
      .get('[data-testid="follow-up-objective"]')
      .setValue('Second touch');
    await clickSave(wrapper);

    expect(updateMock).toHaveBeenLastCalledWith(58, {
      config: {
        follow_up_settings: {
          enabled: true,
          prompt: 'Saved prompt',
          steps: [
            { delay_seconds: 3600, mode: 'ai', objective: 'First touch' },
            { delay_seconds: 86_400, mode: 'ai', objective: 'Second touch' },
          ],
        },
      },
    });

    await wrapper
      .findAll('[data-testid="follow-up-step-remove"]')[0]
      .trigger('click');

    expect(wrapper.findAll('[data-testid="follow-up-step"]')).toHaveLength(1);
    expect(wrapper.get('[data-testid="follow-up-step"]').text()).toContain(
      'Second touch'
    );
  });

  it('validates the steps and the prompt before saving', async () => {
    setSettings({
      enabled: true,
      prompt: 'Saved prompt',
      steps: [{ delay_seconds: 3600, mode: 'ai', objective: 'First touch' }],
    });
    const wrapper = mountTab();

    await wrapper.get('#follow-up-prompt').setValue('   ');
    await clickSave(wrapper);
    expect(useAlertMock).toHaveBeenLastCalledWith(
      'CAPTAIN.ASSISTANTS.FOLLOW_UPS.PROMPT_VALIDATION'
    );

    await wrapper.get('#follow-up-prompt').setValue('Saved prompt');
    await wrapper.get('[data-testid="follow-up-objective"]').setValue('');
    await clickSave(wrapper);
    expect(useAlertMock).toHaveBeenLastCalledWith(
      'CAPTAIN.ASSISTANTS.FOLLOW_UPS.VALIDATION'
    );

    await wrapper.get('[data-testid="follow-up-objective"]').setValue('Again');
    await wrapper.get('[data-testid="follow-up-delay"]').setValue('0');
    await clickSave(wrapper);
    expect(useAlertMock).toHaveBeenLastCalledWith(
      'CAPTAIN.ASSISTANTS.FOLLOW_UPS.VALIDATION'
    );
    expect(updateMock).not.toHaveBeenCalled();
  });

  it('emits dirtyChange when the draft changes and after it is saved', async () => {
    setSettings({
      enabled: true,
      prompt: 'Saved prompt',
      steps: [{ delay_seconds: 3600, mode: 'ai', objective: 'First touch' }],
    });
    const wrapper = mountTab();
    expect(wrapper.vm.isDirty).toBe(false);

    await wrapper.get('#follow-up-prompt').setValue('Changed prompt');
    expect(wrapper.vm.isDirty).toBe(true);
    expect(wrapper.emitted('dirtyChange')).toEqual([[true]]);

    await wrapper.get('#follow-up-prompt').setValue('Saved prompt');
    expect(wrapper.emitted('dirtyChange')).toEqual([[true], [false]]);

    await wrapper.get('#follow-up-prompt').setValue('Changed again');
    expect(await wrapper.vm.save()).toBe(true);
    await flushPromises();
    expect(wrapper.vm.isDirty).toBe(false);
    expect(wrapper.emitted('dirtyChange').at(-1)).toEqual([false]);
  });

  it('reports a failed save and keeps the draft dirty', async () => {
    setSettings({
      enabled: true,
      prompt: 'Saved prompt',
      steps: [{ delay_seconds: 3600, mode: 'ai', objective: 'First touch' }],
    });
    updateMock.mockRejectedValueOnce(new Error('offline'));
    const wrapper = mountTab();

    await wrapper.get('#follow-up-prompt').setValue('Changed prompt');
    await clickSave(wrapper);

    expect(useAlertMock).toHaveBeenLastCalledWith(
      'CAPTAIN.ASSISTANTS.EDIT.ERROR_MESSAGE'
    );
    expect(wrapper.vm.isDirty).toBe(true);
    expect(wrapper.emitted('saved')).toBeUndefined();
  });

  it('shows one compact step editor at a time', async () => {
    setSettings({
      enabled: true,
      steps: [
        { delay_seconds: 3600, mode: 'ai', objective: 'First touch' },
        { delay_seconds: 7200, mode: 'ai', objective: 'Second touch' },
      ],
    });
    const wrapper = mountTab();
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

  it('preserves an unsaved prompt during a background agent refresh', async () => {
    setSettings({
      enabled: true,
      prompt: 'Saved prompt',
      steps: [{ delay_seconds: 3600, mode: 'ai', objective: 'Follow up' }],
    });
    const wrapper = mountTab();
    const prompt = wrapper.get('#follow-up-prompt');
    await prompt.setValue('Unsaved prompt');

    setSettings({
      enabled: true,
      prompt: 'Background prompt',
      steps: [{ delay_seconds: 3600, mode: 'ai', objective: 'Follow up' }],
    });
    await flushPromises();

    expect(prompt.element.value).toBe('Unsaved prompt');
  });

  it('preserves edits made while an earlier draft is being saved', async () => {
    setSettings({
      enabled: true,
      prompt: 'Saved prompt',
      steps: [{ delay_seconds: 3600, mode: 'ai', objective: 'Follow up' }],
    });
    let resolveUpdate;
    updateMock.mockReturnValue(
      new Promise(resolve => {
        resolveUpdate = resolve;
      })
    );
    const wrapper = mountTab();
    const prompt = wrapper.get('#follow-up-prompt');
    await prompt.setValue('Submitted draft');
    await saveButton(wrapper).trigger('click');
    await prompt.setValue('Edited during save');

    resolveUpdate({ data: { id: 58 } });
    await flushPromises();
    setSettings({
      enabled: true,
      prompt: 'Submitted draft',
      steps: [{ delay_seconds: 3600, mode: 'ai', objective: 'Follow up' }],
    });
    await flushPromises();

    expect(prompt.element.value).toBe('Edited during save');
    expect(wrapper.vm.isDirty).toBe(true);
  });
});
