/* eslint-disable vue/one-component-per-file */
import { describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { mount } from '@vue/test-utils';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
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
  { id: 'first', label: 'First', active: true },
  { id: 'second', label: 'Second', active: false },
  { id: 'other', label: 'Other', active: true },
];

const mountSection = (props = {}, slots = {}) =>
  mount(OutcomeReasonSection, {
    props: {
      type: 'handoffReasons',
      icon: 'i-lucide-user-round-forward',
      title: 'Section title',
      description: 'Section description',
      reasons: reasons(),
      ...props,
    },
    slots,
  });

const rowIds = wrapper =>
  wrapper
    .findAll('[data-testid="outcome-reason-row"]')
    .map(row => row.attributes('data-reason-id'));

describe('OutcomeReasonSection', () => {
  it('renders the title, the description and the rows in the given order', () => {
    const wrapper = mountSection();

    expect(wrapper.get('h4').text()).toBe('Section title');
    expect(wrapper.get('p').text()).toBe('Section description');
    expect(rowIds(wrapper)).toEqual(['first', 'second', 'other']);
  });

  it('puts the add button on the right of the header row above the rows', () => {
    const wrapper = mountSection({ reasonsTitle: 'Reasons' });
    const header = wrapper.get('[data-testid="outcome-reasons-header"]');
    const children = [...header.element.children];

    expect(children.at(-1)).toBe(
      wrapper.get('[data-testid="outcome-add-handoffReasons"]').element
    );
    expect(header.classes()).toContain('justify-end');
    expect(header.get('h5').text()).toBe('Reasons');
    expect(header.get('h5').classes()).toContain('mr-auto');
  });

  it('shows the add button alone on the right when there is no subheading', () => {
    const wrapper = mountSection();
    const header = wrapper.get('[data-testid="outcome-reasons-header"]');

    expect(header.find('h5').exists()).toBe(false);
    expect(header.element.children).toHaveLength(1);
    expect(header.classes()).toContain('justify-end');
  });

  it('renders the action slot next to the title', () => {
    const wrapper = mountSection(
      {},
      { action: '<span data-testid="slot-action" />' }
    );

    expect(wrapper.find('[data-testid="slot-action"]').exists()).toBe(true);
  });

  it('hides the list while showReasons is false', () => {
    const wrapper = mountSection({ showReasons: false });

    expect(
      wrapper.find('[data-testid="outcome-reasons-header"]').exists()
    ).toBe(false);
    expect(rowIds(wrapper)).toEqual([]);
    expect(wrapper.find('h4').exists()).toBe(true);
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
    expect(other.get('input[type="checkbox"]').attributes('disabled')).toBe('');
    expect(other.find('[data-testid="outcome-remove"]').exists()).toBe(false);
  });

  it('gives an unsaved row the same markup and the placeholder', () => {
    const wrapper = mountSection({
      reasons: [
        { id: 'first', label: 'First', active: true },
        { id: 'custom_handoff_1', label: '', active: true },
        { id: 'other', label: 'Other', active: true },
      ],
    });
    const rows = wrapper.findAll('[data-testid="outcome-reason-row"]');
    const unsaved = rows[1];

    expect(unsaved.classes()).toEqual(rows[0].classes());
    expect(
      unsaved.get('input:not([type="checkbox"])').attributes()
    ).toMatchObject({ placeholder: 'CAPTAIN.ASSISTANTS.OUTCOMES.PLACEHOLDER' });
    expect(unsaved.get('input:not([type="checkbox"])').element.value).toBe('');
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

  it('disables the add button at the reasons limit', () => {
    const wrapper = mountSection({ maxReasons: 3 });

    expect(
      wrapper
        .get('[data-testid="outcome-add-handoffReasons"]')
        .attributes('disabled')
    ).toBeDefined();
  });

  it('labels the inputs with the reasons subheading, or the title without one', () => {
    const withSubheading = mountSection({ reasonsTitle: 'Reasons' });
    const withoutSubheading = mountSection();
    const label = wrapper =>
      wrapper.get('input:not([type="checkbox"])').attributes('aria-label');

    expect(label(withSubheading)).toBe('Reasons');
    expect(label(withoutSubheading)).toBe('Section title');
  });
});
