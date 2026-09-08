import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import ComboBoxDropdown from '../ComboBoxDropdown.vue';

describe('ComboBoxDropdown', () => {
  it('offers to create the searched value and highlights that value', async () => {
    const wrapper = mount(ComboBoxDropdown, {
      props: {
        createOptionLabel: 'Создать контакт',
        inline: true,
        open: true,
        options: [],
        searchValue: '  фывфы  ',
      },
    });

    const createOption = wrapper.get('[data-testid="combobox-create-option"]');
    const createValue = wrapper.get(
      '[data-testid="combobox-create-option-value"]'
    );
    expect(createOption.attributes('aria-label')).toBe('Создать контакт фывфы');
    expect(createValue.text()).toBe('фывфы');
    expect(createValue.classes()).toContain('text-n-blue-11');

    await createOption.trigger('click');

    expect(wrapper.emitted('create')).toEqual([['фывфы']]);
  });

  it('keeps the create action when search results are present', () => {
    const wrapper = mount(ComboBoxDropdown, {
      props: {
        createOptionLabel: 'Создать компанию',
        inline: true,
        open: true,
        options: [{ label: 'Фывфы существующая', value: 1 }],
        searchValue: 'фывфы',
      },
    });

    expect(wrapper.text()).toContain('Фывфы существующая');
    expect(
      wrapper.get('[data-testid="combobox-create-option-value"]').text()
    ).toBe('фывфы');
  });

  it('keeps the regular empty state when creation is unavailable', () => {
    const wrapper = mount(ComboBoxDropdown, {
      props: {
        emptyState: 'Контакты не найдены',
        inline: true,
        open: true,
        options: [],
        searchValue: 'фывфы',
      },
    });

    expect(wrapper.text()).toContain('Контакты не найдены');
    expect(
      wrapper.find('[data-testid="combobox-create-option"]').exists()
    ).toBe(false);
  });
});
