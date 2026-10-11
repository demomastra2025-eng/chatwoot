/* eslint-disable vue/one-component-per-file */
import { describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { mount } from '@vue/test-utils';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, te: () => true }),
}));

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

const { default: OutcomeReasonSection } = await import(
  './OutcomeReasonSection.vue'
);

const reasons = () => [
  { id: 'first', label: 'First', enabled: true, builtin: false },
  { id: 'second', label: 'Second', enabled: false, builtin: false },
  { id: 'other', label: 'Other', enabled: true, builtin: true },
];

const mountSection = (props = {}) =>
  mount(OutcomeReasonSection, {
    props: {
      type: 'handoffReasons',
      title: 'Section title',
      description: 'Section description',
      reasons: reasons(),
      ...props,
    },
  });

const rowIds = wrapper =>
  wrapper
    .findAll('[data-testid="outcome-reason-row"]')
    .map(row => row.attributes('data-reason-id'));
const labelInput = row => row.get('input:not([type="checkbox"])');

describe('OutcomeReasonSection', () => {
  it('renders the title, the description and the rows in the given order', () => {
    const wrapper = mountSection();

    expect(wrapper.get('h4').text()).toBe('Section title');
    expect(wrapper.get('header p').text()).toBe('Section description');
    expect(rowIds(wrapper)).toEqual(['first', 'second', 'other']);
  });

  it('puts the add button in the footer row under the list', () => {
    const wrapper = mountSection();
    const footer = wrapper.get('[data-testid="outcome-reasons-footer"]');

    expect(
      footer.find('[data-testid="outcome-add-handoffReasons"]').exists()
    ).toBe(true);
    expect(footer.find('[role="alert"]').exists()).toBe(false);
  });

  it('locks the system reason and removes its delete button', () => {
    const wrapper = mountSection();
    const [first, second, other] = wrapper.findAll(
      '[data-testid="outcome-reason-row"]'
    );

    [first, second].forEach(row => {
      expect(row.get('input[type="checkbox"]').attributes('disabled')).toBe(
        undefined
      );
      expect(row.find('[data-testid="outcome-remove"]').exists()).toBe(true);
    });
    expect(other.find('input[type="checkbox"]').exists()).toBe(false);
    expect(other.find('[data-testid="outcome-remove"]').exists()).toBe(false);
  });

  it('binds the enabled flag of the API reason shape', async () => {
    const rows = reasons();
    const wrapper = mountSection({ reasons: rows });
    const [first, second] = wrapper.findAll(
      '[data-testid="outcome-reason-row"]'
    );

    expect(first.get('input[type="checkbox"]').element.checked).toBe(true);
    expect(second.get('input[type="checkbox"]').element.checked).toBe(false);
    await second.get('input[type="checkbox"]').setValue(true);
    await labelInput(first).setValue('Renamed');

    expect(rows[1].enabled).toBe(true);
    expect(rows[0].label).toBe('Renamed');
    expect(rows[1]).not.toHaveProperty('active');
  });

  it('gives an unsaved row the same markup and the placeholder', () => {
    const wrapper = mountSection({
      reasons: [
        { id: 'first', label: 'First', enabled: true },
        { id: 'custom_handoff_1', label: '', enabled: true },
        { id: 'other', label: 'Other', enabled: true },
      ],
    });
    const rows = wrapper.findAll('[data-testid="outcome-reason-row"]');
    const unsaved = rows[1];

    expect(unsaved.classes()).toEqual(rows[0].classes());
    expect(labelInput(unsaved).attributes()).toMatchObject({
      placeholder: 'CAPTAIN.ASSISTANTS.OUTCOMES.PLACEHOLDER',
      maxlength: '255',
    });
    expect(labelInput(unsaved).element.value).toBe('');
  });

  it('emits add and remove with the reason id', async () => {
    const wrapper = mountSection();

    await wrapper
      .get('[data-testid="outcome-add-handoffReasons"]')
      .trigger('click');
    await wrapper.findAll('[data-testid="outcome-remove"]')[1].trigger('click');

    expect(wrapper.emitted('add')).toHaveLength(1);
    expect(wrapper.emitted('remove')).toEqual([['second']]);
  });

  it('disables the add button and shows a note at the reasons limit', () => {
    const wrapper = mountSection({ maxReasons: 3 });

    expect(
      wrapper
        .get('[data-testid="outcome-add-handoffReasons"]')
        .attributes('disabled')
    ).toBeDefined();
    expect(wrapper.text()).toContain(
      'CAPTAIN.AI_SETTINGS.HANDOFF.REASONS_LIMIT'
    );
  });

  it('labels the inputs with the block title', () => {
    const wrapper = mountSection();
    const row = wrapper.get('[data-testid="outcome-reason-row"]');

    expect(labelInput(row).attributes('aria-label')).toBe('Section title');
  });

  it('keeps ordinary builtins switchable and hides their delete buttons', async () => {
    const rows = [
      { id: 'goal_achieved', label: 'Goal achieved', enabled: true },
      { id: 'clinic_reason', label: 'Clinic', enabled: false, builtin: true },
    ];
    const wrapper = mountSection({ reasons: rows });
    const rendered = wrapper.findAll('[data-testid="outcome-reason-row"]');
    expect(
      rendered.every(
        row => !row.find('[data-testid="outcome-remove"]').exists()
      )
    ).toBe(true);
    await rendered[0].get('input[type="checkbox"]').setValue(false);
    await rendered[1].get('input[type="checkbox"]').setValue(true);
    expect(rows.map(row => row.enabled)).toEqual([false, true]);
  });

  it('renders a locked reason with no switch or delete control', () => {
    const wrapper = mountSection({
      reasons: [
        {
          id: 'faq_no_answer',
          label: 'No FAQ answer',
          enabled: true,
          locked: true,
        },
      ],
    });
    const row = wrapper.get('[data-testid="outcome-reason-row"]');
    expect(row.find('input[type="checkbox"]').exists()).toBe(false);
    expect(row.find('[data-testid="outcome-remove"]').exists()).toBe(false);
    expect(labelInput(row).element.value).toBe('No FAQ answer');
  });

  it('marks empty labels and shows the list error after a save attempt', () => {
    const wrapper = mountSection({
      showErrors: true,
      error: 'Fill in the reasons',
      reasons: [
        { id: 'first', label: 'First', enabled: true },
        { id: 'custom_handoff_1', label: '  ', enabled: true },
      ],
    });
    const [filled, empty] = wrapper.findAll(
      '[data-testid="outcome-reason-row"]'
    );

    expect(labelInput(filled).attributes('aria-invalid')).toBeUndefined();
    expect(labelInput(empty).attributes('aria-invalid')).toBe('true');
    expect(wrapper.get('[role="alert"]').text()).toBe('Fill in the reasons');
  });

  it('is one block whose rows are divided, never framed', () => {
    const wrapper = mountSection();
    expect(wrapper.classes()).toEqual(
      expect.arrayContaining(['rounded-xl', 'outline', 'outline-n-weak'])
    );
    expect(wrapper.get('ul').classes()).toContain('divide-y');
    wrapper.findAll('[data-testid="outcome-reason-row"]').forEach(row => {
      expect(row.classes()).not.toContain('rounded-lg');
      expect(row.classes()).not.toContain('rounded-xl');
      expect(row.classes()).not.toContain('border');
      expect(row.classes()).not.toContain('outline');
    });
  });
});
