/* eslint-disable vue/one-component-per-file */
import { describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { mount } from '@vue/test-utils';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock(
  'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue',
  () => ({
    default: defineComponent({ name: 'SettingsHeader', template: '<div />' }),
  })
);

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: defineComponent({
    name: 'ButtonStub',
    inheritAttrs: false,
    props: {
      label: { type: String, default: '' },
      disabled: Boolean,
    },
    emits: ['click'],
    setup(props, { attrs, emit }) {
      return () =>
        h(
          'button',
          {
            ...attrs,
            disabled: props.disabled,
            onClick: () => emit('click'),
          },
          props.label
        );
    },
  }),
}));

vi.mock('dashboard/components-next/switch/Switch.vue', () => ({
  default: defineComponent({
    name: 'SwitchStub',
    inheritAttrs: false,
    props: {
      modelValue: Boolean,
      disabled: Boolean,
    },
    emits: ['update:modelValue'],
    setup(props, { attrs, emit }) {
      return () =>
        h('input', {
          ...attrs,
          type: 'checkbox',
          checked: props.modelValue,
          disabled: props.disabled,
          onChange: event => emit('update:modelValue', event.target.checked),
        });
    },
  }),
}));

const { default: OutcomesForm } = await import('./Index.vue');
const mountComponent = (config = {}) =>
  mount(OutcomesForm, {
    props: {
      assistant: { id: 58, config },
      handoffEnabled: config.handoff_enabled !== false,
    },
  });

describe('Captain assistant outcome settings form', () => {
  it('enables both capabilities by default and exposes stable reasons', async () => {
    const wrapper = mountComponent();

    expect(wrapper.findAll('[data-testid="outcome-reason-row"]')).toHaveLength(
      11
    );
    expect(
      wrapper.find('[data-testid="outcome-toggle-handoffReasons"]').exists()
    ).toBe(false);

    const payload = await wrapper.vm.buildPayload();
    expect(payload.assistant.config).toMatchObject({
      auto_completion_enabled: true,
    });
    expect(payload.assistant.config).not.toHaveProperty('handoff_enabled');
    expect(
      payload.assistant.config.outcome_reason_settings.completion_reasons
    ).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: 'goal_achieved', active: true }),
        expect.objectContaining({ id: 'other', active: true }),
      ])
    );
  });

  it('hides handoff reasons when the existing capability is disabled', async () => {
    const wrapper = mountComponent({ handoff_enabled: false });

    expect(
      wrapper.find('[data-testid="outcome-section-handoffReasons"]').exists()
    ).toBe(false);
    expect(
      wrapper
        .get('[data-testid="outcome-section-completionReasons"]')
        .find('[data-testid="outcome-reason-row"]')
        .exists()
    ).toBe(true);

    const payload = await wrapper.vm.buildPayload();
    expect(payload.assistant.config).not.toHaveProperty('handoff_enabled');
  });

  it('hides completion reasons when automatic completion is disabled', async () => {
    const wrapper = mountComponent({ auto_completion_enabled: false });

    expect(
      wrapper
        .get('[data-testid="outcome-section-completionReasons"]')
        .find('[data-testid="outcome-reason-row"]')
        .exists()
    ).toBe(false);

    const payload = await wrapper.vm.buildPayload();
    expect(payload.assistant.config.auto_completion_enabled).toBe(false);
  });

  it('keeps reason ids stable when labels are renamed', async () => {
    const wrapper = mountComponent({
      outcome_reason_settings: {
        completion_reasons: [{ id: 'goal_achieved', label: 'Old label' }],
        handoff_reasons: [{ id: 'low_confidence', label: 'Needs human' }],
      },
    });

    const completionInput = wrapper
      .get('[data-testid="outcome-section-completionReasons"]')
      .get('input:not([type="checkbox"])');
    await completionInput.setValue('Renamed label');

    const payload = await wrapper.vm.buildPayload();
    expect(
      payload.assistant.config.outcome_reason_settings.completion_reasons
    ).toEqual(
      expect.arrayContaining([
        { id: 'goal_achieved', label: 'Renamed label', active: true },
        expect.objectContaining({ id: 'other', active: true }),
      ])
    );
  });

  it('preserves an unsaved reason label during a background assistant refresh', async () => {
    const wrapper = mountComponent({
      outcome_reason_settings: {
        completion_reasons: [{ id: 'goal_achieved', label: 'Saved label' }],
      },
    });
    const completionInput = wrapper
      .get('[data-testid="outcome-section-completionReasons"]')
      .get('input:not([type="checkbox"])');
    await completionInput.setValue('Unsaved draft');

    await wrapper.setProps({
      assistant: {
        id: 58,
        config: {
          outcome_reason_settings: {
            completion_reasons: [
              { id: 'goal_achieved', label: 'Background value' },
            ],
          },
        },
      },
    });

    expect(completionInput.element.value).toBe('Unsaved draft');
  });

  it('does not allow removing or disabling the required other fallback', () => {
    const wrapper = mountComponent();
    const otherRows = wrapper.findAll('[data-reason-id="other"]');

    expect(otherRows).toHaveLength(2);
    expect(
      otherRows.every(
        row =>
          !row.find('[data-testid="outcome-remove"]').exists() &&
          row.get('input[type="checkbox"]').attributes('disabled') !== undefined
      )
    ).toBe(true);
  });

  it('validates empty reasons only while their capability is enabled', async () => {
    const wrapper = mountComponent();
    await wrapper
      .get('[data-testid="outcome-add-completionReasons"]')
      .trigger('click');

    expect(await wrapper.vm.buildPayload()).toBeNull();

    await wrapper
      .get('[data-testid="outcome-toggle-completionReasons"]')
      .setValue(false);
    const payload = await wrapper.vm.buildPayload();
    expect(payload).not.toBeNull();
    expect(
      payload.assistant.config.outcome_reason_settings.completion_reasons
    ).not.toEqual(
      expect.arrayContaining([expect.objectContaining({ label: '' })])
    );
  });
});
