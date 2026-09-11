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
});
