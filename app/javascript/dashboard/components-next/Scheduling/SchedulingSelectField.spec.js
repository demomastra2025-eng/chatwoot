import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import SchedulingSelectField from './SchedulingSelectField.vue';

const mountComponent = (props = {}) =>
  mount(SchedulingSelectField, {
    attachTo: document.body,
    props: {
      modelValue: '',
      options: [{ label: 'Contact', value: 1 }],
      searchPlaceholder: 'Search contacts',
      ...props,
    },
  });

describe('SchedulingSelectField', () => {
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

  it('searches in the visible field without rendering a second search input', async () => {
    const wrapper = mountComponent({
      inlineDropdown: true,
      modelValue: 1,
      searchInTrigger: true,
    });
    const searchInput = wrapper.get('input[placeholder="Search contacts"]');

    expect(searchInput.element.value).toBe('Contact');
    expect(searchInput.classes()).toContain('rounded-lg');
    expect(searchInput.element.parentElement.classList).not.toContain(
      'rounded-lg'
    );
    expect(searchInput.classes()).toContain('!pl-3');
    expect(wrapper.find('.i-lucide-search').exists()).toBe(false);

    await searchInput.trigger('focus');
    await wrapper.vm.$nextTick();

    expect(wrapper.emitted('open')).toHaveLength(1);
    expect(
      document.body.querySelectorAll('input[placeholder="Search contacts"]')
    ).toHaveLength(1);

    await searchInput.setValue('Иванов Иван');

    expect(wrapper.emitted('search').at(-1)).toEqual(['Иванов Иван']);
    const dropdown = wrapper.get('.dashboard-combobox-dropdown');
    expect(dropdown.get('ul').exists()).toBe(true);
    expect(dropdown.classes()).toContain('absolute');
    expect(dropdown.classes()).not.toContain('fixed');
    expect(dropdown.classes()).not.toContain('backdrop-blur-[16px]');

    wrapper.unmount();
  });

  it('debounces API-backed contact search to the completed query', async () => {
    vi.useFakeTimers();
    const wrapper = mountComponent({
      searchDebounceMs: 250,
      searchInTrigger: true,
    });

    try {
      const searchInput = wrapper.get('input[placeholder="Search contacts"]');
      await searchInput.trigger('focus');
      await searchInput.setValue('Ас');
      await searchInput.setValue('Асет');

      expect(wrapper.emitted('search')).toBeUndefined();

      await vi.advanceTimersByTimeAsync(250);

      expect(wrapper.emitted('search')).toEqual([['Асет']]);
    } finally {
      wrapper.unmount();
      vi.useRealTimers();
    }
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
});
