import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import ComboBox from '../ComboBox.vue';
import ComboBoxDropdown from '../ComboBoxDropdown.vue';
import TagMultiSelectComboBox from '../TagMultiSelectComboBox.vue';

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
    expect(createOption.attributes('tabindex')).toBe('0');
    expect(createValue.text()).toBe('фывфы');
    expect(createValue.classes()).toContain('text-n-blue-11');

    await createOption.trigger('click');

    expect(wrapper.emitted('create')).toEqual([['фывфы']]);
  });

  it.each(['enter', 'space'])(
    'allows keyboard users to create with %s',
    async key => {
      const wrapper = mount(ComboBoxDropdown, {
        props: {
          createOptionLabel: 'Создать',
          inline: true,
          open: true,
          options: [],
          searchValue: '  Новая запись  ',
        },
      });

      await wrapper
        .get('[data-testid="combobox-create-option"]')
        .trigger(`keydown.${key}`);

      expect(wrapper.emitted('create')).toEqual([['Новая запись']]);
    }
  );

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

  it.each([
    ['single select', ComboBox, wrapper => wrapper.vm.open()],
    [
      'tag multi-select',
      TagMultiSelectComboBox,
      wrapper => wrapper.vm.toggleDropdown(),
    ],
  ])(
    'creates through the %s DOM path and clears the dropdown state',
    async (_, component, openDropdown) => {
      const wrapper = mount(component, {
        props: {
          createOptionLabel: 'Создать',
          inlineDropdown: true,
          options: [],
        },
        global: {
          stubs: {
            Teleport: true,
          },
        },
      });

      openDropdown(wrapper);
      await wrapper.vm.$nextTick();

      const searchInput = wrapper.get('.dashboard-combobox-dropdown input');
      await searchInput.setValue('  Новая запись  ');
      await wrapper
        .get('[data-testid="combobox-create-option"]')
        .trigger('click');
      await wrapper.vm.$nextTick();

      expect(wrapper.emitted('create')).toEqual([['Новая запись']]);
      expect(
        wrapper.get('.dashboard-combobox-dropdown input').element.value
      ).toBe('');
      expect(wrapper.get('.dashboard-combobox-dropdown').isVisible()).toBe(
        false
      );
    }
  );
});
