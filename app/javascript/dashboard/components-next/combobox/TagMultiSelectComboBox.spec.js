import { afterEach, describe, expect, it } from 'vitest';
import { mount } from '@vue/test-utils';
import { readonly } from 'vue';

import TagMultiSelectComboBox from './TagMultiSelectComboBox.vue';

const options = [
  { label: 'Первичный приём', value: 1 },
  { label: 'Повторный приём', value: 2 },
  { label: 'Check-up', value: 3 },
];

describe('TagMultiSelectComboBox', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('selects services from a readonly parent array without mutating it, including after a parent update', async () => {
    const initialValues = readonly([]);
    const wrapper = mount(TagMultiSelectComboBox, {
      attachTo: document.body,
      props: { modelValue: initialValues, options },
      global: {
        stubs: {
          OnClickOutside: {
            template: '<div><slot /></div>',
          },
        },
      },
    });

    await wrapper.get('button').trigger('click');
    const firstOption = document.querySelector('[role="option"]');
    firstOption.click();
    await wrapper.vm.$nextTick();

    const firstSelection = wrapper.emitted('update:modelValue')[0][0];
    expect(firstSelection).toEqual([1]);
    expect(firstSelection).not.toBe(initialValues);
    expect(initialValues).toEqual([]);
    expect(firstOption.getAttribute('aria-selected')).toBe('true');

    const updatedValues = readonly([2]);
    await wrapper.setProps({ modelValue: updatedValues });
    firstOption.click();
    await wrapper.vm.$nextTick();

    const nextSelection = wrapper.emitted('update:modelValue')[1][0];
    expect(nextSelection).toEqual([2, 1]);
    expect(nextSelection).not.toBe(updatedValues);
    expect(updatedValues).toEqual([2]);
    expect(firstOption.getAttribute('aria-selected')).toBe('true');

    wrapper.unmount();
  });

  it('filters local options immediately while typing', async () => {
    const wrapper = mount(TagMultiSelectComboBox, {
      attachTo: document.body,
      props: { options },
      global: {
        stubs: {
          OnClickOutside: {
            template: '<div><slot /></div>',
          },
        },
      },
    });

    await wrapper.get('button').trigger('click');
    await document.querySelector('.dashboard-combobox-dropdown input').focus();
    await wrapper.vm.$nextTick();

    const input = document.querySelector('.dashboard-combobox-dropdown input');
    input.value = 'первич';
    input.dispatchEvent(new Event('input', { bubbles: true }));
    await wrapper.vm.$nextTick();

    const renderedOptions = [
      ...document.querySelectorAll('[role="option"]'),
    ].map(option => option.textContent.trim());
    expect(renderedOptions).toEqual(['Первичный приём']);

    wrapper.unmount();
  });

  it('normalizes non-breaking spaces while searching', async () => {
    const wrapper = mount(TagMultiSelectComboBox, {
      attachTo: document.body,
      props: {
        options: [{ label: 'Первичный\u00a0приём кардиолога', value: 1 }],
      },
      global: {
        stubs: {
          OnClickOutside: {
            template: '<div><slot /></div>',
          },
        },
      },
    });

    await wrapper.get('button').trigger('click');
    const input = document.querySelector('.dashboard-combobox-dropdown input');
    input.value = 'первичный приём';
    input.dispatchEvent(new Event('input', { bubbles: true }));
    await wrapper.vm.$nextTick();

    expect(document.querySelector('[role="option"]').textContent).toContain(
      'Первичный\u00a0приём кардиолога'
    );

    wrapper.unmount();
  });

  it('shows a selected long label without truncation when requested', () => {
    const wrapper = mount(TagMultiSelectComboBox, {
      props: {
        modelValue: [1],
        options: [
          { label: 'Полное наименование медицинской услуги', value: 1 },
        ],
        wrapLabels: true,
      },
    });

    const selectedLabel = wrapper.get('span[title]');
    expect(selectedLabel.classes()).toContain('whitespace-normal');
    expect(selectedLabel.classes()).not.toContain('truncate');
    expect(selectedLabel.attributes('title')).toBe(
      'Полное наименование медицинской услуги'
    );
  });

  it('exposes separate native tag actions, preserves links and moves focus after removal', async () => {
    const wrapper = mount(TagMultiSelectComboBox, {
      attachTo: document.body,
      props: {
        options: [
          { value: 1, label: 'First', href: '/app/first' },
          { value: 2, label: 'Second' },
        ],
        modelValue: [1, 2],
      },
      global: {
        stubs: { OnClickOutside: { template: '<div><slot /></div>' } },
      },
    });
    const trigger = wrapper.get('button[aria-haspopup="listbox"]');
    const link = wrapper.get('a');
    expect(link.element.closest('button')).toBeNull();
    expect(link.attributes('href')).toBe('/app/first');
    const click = new MouseEvent('click', { bubbles: true, cancelable: true });
    link.element.dispatchEvent(click);
    expect(click.defaultPrevented).toBe(false);
    expect(wrapper.vm.open).toBe(false);
    const remove = wrapper.get('[data-tag-remove]');
    expect(remove.element.tagName).toBe('BUTTON');
    expect(remove.attributes('type')).toBe('button');
    expect(remove.attributes('aria-label')).toBe('Remove First');
    remove.element.focus();
    remove.element.click();
    await wrapper.vm.$nextTick();
    await wrapper.vm.$nextTick();
    expect(wrapper.emitted('update:modelValue').at(-1)).toEqual([[2]]);
    expect(document.activeElement).toBe(
      wrapper.get('[data-tag-remove]').element
    );
    wrapper.get('[data-tag-remove]').element.click();
    await wrapper.vm.$nextTick();
    await wrapper.vm.$nextTick();
    expect(document.activeElement).toBe(trigger.element);
    expect(wrapper.vm.open).toBe(false);
    wrapper.unmount();
  });

  it('keeps removal and the list trigger disabled without mutating selected values', () => {
    const wrapper = mount(TagMultiSelectComboBox, {
      props: { options, modelValue: [1], disabled: true },
    });
    const remove = wrapper.get('[data-tag-remove]');
    expect(remove.element.disabled).toBe(true);
    remove.element.click();
    expect(wrapper.emitted('update:modelValue')).toBeUndefined();
    expect(wrapper.get('button[aria-haspopup]').element.disabled).toBe(true);
    wrapper.unmount();
  });

  it('previews the full selected label on open without changing selection', async () => {
    const label =
      'Магниторезонансная томография головного мозга с оценкой перфузии, МРТ-трактографией (C03.015.007)';
    const secondLabel =
      'Контрастное усиление для магнитно-резонансной томографии';
    const wrapper = mount(TagMultiSelectComboBox, {
      attachTo: document.body,
      props: {
        modelValue: [1, 2],
        options: [
          { label, value: 1 },
          { label: secondLabel, value: 2 },
        ],
        wrapLabels: true,
        clampSelectedLabels: true,
        showSelectedLabelPreview: true,
      },
      global: {
        stubs: {
          OnClickOutside: {
            template: '<div><slot /></div>',
          },
        },
      },
    });

    await wrapper.get('button').trigger('click');

    expect(
      document.querySelector('.combobox-selected-label-preview').textContent
    ).toBe([label, secondLabel].join('\n'));
    expect(wrapper.emitted('update:modelValue')).toBeUndefined();

    wrapper.unmount();
  });
});
