import { mount } from '@vue/test-utils';
import { afterEach, describe, expect, it } from 'vitest';

import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import SchedulingSelectField from './SchedulingSelectField.vue';

const mountComponent = () =>
  mount(SchedulingSelectField, {
    attachTo: document.body,
    props: {
      modelValue: '',
      options: [{ label: 'Contact', value: 1 }],
      searchPlaceholder: 'Search contacts',
    },
  });

describe('SchedulingSelectField', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('opens the existing searchable combobox programmatically', async () => {
    const wrapper = mountComponent();

    wrapper.vm.open();
    await wrapper.vm.$nextTick();

    expect(wrapper.emitted('open')).toHaveLength(1);
    expect(
      document.body.querySelector('input[placeholder="Search contacts"]')
    ).not.toBeNull();

    wrapper.unmount();
  });

  it('aligns an end-positioned dropdown to the right edge of its trigger', async () => {
    const wrapper = mount(ComboBox, {
      attachTo: document.body,
      props: {
        dropdownAlign: 'end',
        dropdownMinWidth: 405,
        options: [{ label: 'Contact', value: 1 }],
      },
    });

    wrapper.element.getBoundingClientRect = () => ({
      bottom: 140,
      height: 40,
      left: 700,
      right: 800,
      top: 100,
      width: 100,
      x: 700,
      y: 100,
      toJSON: () => {},
    });

    wrapper.vm.open();
    await wrapper.vm.$nextTick();
    await wrapper.vm.$nextTick();

    const dropdown = document.body.querySelector(
      '.dashboard-combobox-dropdown'
    );
    expect(dropdown.style.left).toBe('395px');
    expect(dropdown.style.width).toBe('405px');

    wrapper.unmount();
  });

  it('shows a selected long label without truncation when requested', () => {
    const label = 'Полное наименование медицинской услуги';
    const wrapper = mount(SchedulingSelectField, {
      props: {
        modelValue: 1,
        options: [{ label, value: 1, wrapLabel: true }],
        wrapLabel: true,
      },
    });

    const selectedLabel = wrapper.get(`span[title="${label}"]`);
    expect(selectedLabel.classes()).toContain('whitespace-normal');
    expect(selectedLabel.classes()).not.toContain('truncate');

    wrapper.unmount();
  });

  it('normalizes non-breaking spaces while searching', async () => {
    const wrapper = mount(SchedulingSelectField, {
      attachTo: document.body,
      props: {
        modelValue: '',
        options: [{ label: 'Первичный\u00a0приём кардиолога', value: 1 }],
        searchPlaceholder: 'Search services',
      },
    });

    wrapper.vm.open();
    await wrapper.vm.$nextTick();
    const input = document.body.querySelector(
      'input[placeholder="Search services"]'
    );
    input.value = 'первичный приём';
    input.dispatchEvent(new Event('input', { bubbles: true }));
    await wrapper.vm.$nextTick();

    expect(
      document.body.querySelector('[role="option"]').textContent
    ).toContain('Первичный\u00a0приём кардиолога');

    wrapper.unmount();
  });
});
