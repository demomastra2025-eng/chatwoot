import { afterEach, describe, expect, it } from 'vitest';
import { mount } from '@vue/test-utils';

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

    const selectedLabel = wrapper.get('button span[title]');
    expect(selectedLabel.classes()).toContain('whitespace-normal');
    expect(selectedLabel.classes()).not.toContain('truncate');
    expect(selectedLabel.attributes('title')).toBe(
      'Полное наименование медицинской услуги'
    );
  });
});
