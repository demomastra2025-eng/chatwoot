import { mount } from '@vue/test-utils';
import { afterEach, describe, expect, it, vi } from 'vitest';

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

  it('keeps a remote patient row within a 375-pixel viewport and reaches it by keyboard', async () => {
    const width = vi.spyOn(window, 'innerWidth', 'get').mockReturnValue(375);
    const patient = {
      token: 'opaque',
      fullName: 'Қуаныш Аян Болатұлы',
      birthDate: '01.01.2000',
      iinMasked: 'ЖСН ••••0001',
    };
    const wrapper = mountComponent({
      dropdownMinWidth: 405,
      remoteOptions: [patient],
      remoteTitle: 'MedElement жүйесінен табылды',
    });
    wrapper.findComponent(ComboBox).element.getBoundingClientRect = () => ({
      bottom: 140,
      height: 40,
      left: 250,
      right: 350,
      top: 100,
      width: 100,
      x: 250,
      y: 100,
      toJSON: () => {},
    });

    wrapper.vm.open();
    await wrapper.vm.$nextTick();
    await wrapper.vm.$nextTick();
    const dropdown = document.body.querySelector(
      '.dashboard-combobox-dropdown'
    );
    expect(dropdown.style.width).toBe('359px');
    expect(dropdown.style.left).toBe('8px');
    expect(dropdown.textContent).toContain(patient.fullName);
    const input = dropdown.querySelector('input');
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true })
    );
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true })
    );
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })
    );
    await wrapper.vm.$nextTick();
    expect(wrapper.emitted('selectRemote')).toEqual([[patient]]);
    wrapper.unmount();
    width.mockRestore();
  });

  it('keeps local options visible when the remote search fails', async () => {
    const wrapper = mountComponent({
      remoteTitle: 'Найдено в МедЭлементе',
      remoteError: true,
      remoteErrorLabel: 'МедЭлемент не ответил, повторите',
    });
    wrapper.vm.open();
    await wrapper.vm.$nextTick();

    const text = document.body.querySelector(
      '.dashboard-combobox-dropdown'
    ).textContent;
    expect(text).toContain('Contact');
    expect(text).toContain('МедЭлемент не ответил, повторите');
    wrapper.unmount();
  });

  it('flips dropdown placement above the trigger when near the bottom of the viewport so all options remain visible', async () => {
    const wrapper = mount(ComboBox, {
      attachTo: document.body,
      props: {
        options: [
          { label: 'Do not change stage', value: '' },
          { label: 'Booked', value: 1 },
          { label: 'Cancelled', value: 2 },
        ],
      },
    });

    wrapper.element.getBoundingClientRect = () => ({
      bottom: window.innerHeight - 40,
      height: 40,
      left: 100,
      right: 300,
      top: window.innerHeight - 80,
      width: 200,
      x: 100,
      y: window.innerHeight - 80,
      toJSON: () => {},
    });

    wrapper.vm.open();
    await wrapper.vm.$nextTick();
    await wrapper.vm.$nextTick();

    const dropdown = document.body.querySelector(
      '.dashboard-combobox-dropdown'
    );
    expect(dropdown.style.top).toBe('auto');
    expect(dropdown.style.bottom).toBe('88px');
    expect(parseInt(dropdown.style.maxHeight, 10)).toBeGreaterThan(250);

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
