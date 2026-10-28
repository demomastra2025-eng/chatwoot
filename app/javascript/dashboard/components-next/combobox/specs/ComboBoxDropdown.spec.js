import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import ComboBox from '../ComboBox.vue';
import ComboBoxDropdown from '../ComboBoxDropdown.vue';
import TagMultiSelectComboBox from '../TagMultiSelectComboBox.vue';

describe('ComboBoxDropdown', () => {
  const patientProps = {
    inline: true,
    open: true,
    options: [],
    localTitle: 'В OneLink не найдено',
    remoteTitle: 'МедЭлемент',
    remoteEmptyLabel: 'В МедЭлементе не найдено',
    remoteLoadingLabel: 'Ищем в МедЭлементе…',
    remoteErrorLabel: 'МедЭлемент не ответил',
    remoteRetryLabel: 'Повторить',
    remoteNoPhoneLabel: 'без телефона',
    remotePhoneLabel: 'Телефон',
    remoteHint: 'ИИН, телефон или 3+ буквы фамилии',
    createOptionLabel: '+ Новый пациент',
    showCreateAlways: true,
  };

  it.each([
    ['hint', {}, 'ИИН, телефон или 3+ буквы фамилии'],
    [
      'searching',
      { remoteLoading: true, remoteHint: '' },
      'Ищем в МедЭлементе…',
    ],
    [
      'empty',
      { remoteStatus: 'empty', remoteHint: '' },
      'В МедЭлементе не найдено',
    ],
    ['error', { remoteError: true, remoteHint: '' }, 'МедЭлемент не ответил'],
  ])('shows the MedElement %s state', (_, overrides, message) => {
    const wrapper = mount(ComboBoxDropdown, {
      props: { ...patientProps, ...overrides },
    });
    expect(wrapper.text()).toContain(message);
    expect(
      wrapper.find('[data-testid="combobox-create-option"]').exists()
    ).toBe(true);
    if (overrides.remoteStatus === 'empty') {
      const empty = wrapper.get('[data-testid="combobox-remote-empty"]');
      expect(empty.element.nextElementSibling).toBe(
        wrapper.get('[data-testid="combobox-create-option"]').element
      );
    }
  });

  it('shows a selectable found row with masked identity and retries an error', async () => {
    const wrapper = mount(ComboBoxDropdown, {
      props: {
        ...patientProps,
        localTitle: 'В OneLink: 1',
        options: [{ label: 'Локальный пациент', value: 1 }],
        remoteTitle: 'Найдено в МедЭлементе · 1',
        remoteStatus: 'found',
        remoteHint: '',
        remoteOptions: [
          {
            token: 'fake-token',
            fullName: 'Қуаныш Аян',
            birthDate: '01.01.2000',
            iinMasked: 'ИИН ••••0123',
            phoneMasked: '••••0001',
          },
        ],
      },
    });
    expect(wrapper.text()).toContain('В OneLink: 1');
    expect(wrapper.text()).toContain('Найдено в МедЭлементе · 1');
    expect(wrapper.text()).toContain('01.01.2000');
    expect(wrapper.text()).toContain('ИИН ••••0123');
    expect(wrapper.text()).toContain('••••0001');
    expect(wrapper.text()).toContain('Телефон ••••0001');
    await wrapper.findAll('li[role="option"]')[1].trigger('click');
    expect(wrapper.emitted('selectRemote')?.[0]?.[0]?.token).toBe('fake-token');
    await wrapper.setProps({
      remoteError: true,
      remoteStatus: 'error',
      remoteOptions: [],
    });
    await wrapper.get('[data-testid="combobox-remote-retry"]').trigger('click');
    expect(wrapper.emitted('retryRemote')).toHaveLength(1);
  });

  it('shows OneLink searching, found, and empty states and a phone-less MedElement row', async () => {
    const wrapper = mount(ComboBoxDropdown, {
      props: {
        ...patientProps,
        localTitle: 'В OneLink: 1',
        options: [{ label: 'Локальный пациент', value: 1 }],
        remoteTitle: 'Найдено в МедЭлементе · 1',
        remoteHint: '',
        remoteStatus: 'found',
        remoteOptions: [{ token: 'fake-token', fullName: 'Қуаныш Аян' }],
      },
    });
    expect(wrapper.text()).toContain('В OneLink: 1');
    expect(wrapper.text()).toContain('Локальный пациент');
    expect(wrapper.text()).toContain('без телефона');
    expect(wrapper.text()).not.toContain('В OneLink не найдено');
    await wrapper.setProps({
      localTitle: 'Ищем в OneLink…',
      localLoading: true,
    });
    expect(wrapper.text()).toContain('Ищем в OneLink…');
    expect(wrapper.text()).not.toContain('Локальный пациент');
    expect(mount(ComboBoxDropdown, { props: patientProps }).text()).toContain(
      'В OneLink не найдено'
    );
  });
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

  it('keeps a patient creation action below remote results with an empty query', async () => {
    const wrapper = mount(ComboBoxDropdown, {
      props: {
        createOptionLabel: '+ Новый пациент',
        showCreateAlways: true,
        inline: true,
        open: true,
        options: [{ label: 'Пациент OneLink', value: 1 }],
        remoteOptions: [
          { token: 'fake-token', fullName: 'Пациент МедЭлемент' },
        ],
        remoteTitle: 'Найдено в МедЭлементе',
        searchValue: '',
      },
    });

    const createOption = wrapper.get('[data-testid="combobox-create-option"]');
    expect(createOption.attributes('aria-label')).toBe('+ Новый пациент');
    expect(wrapper.text().indexOf('Пациент МедЭлемент')).toBeLessThan(
      wrapper.text().indexOf('+ Новый пациент')
    );
    await createOption.trigger('click');
    expect(wrapper.emitted('create')).toEqual([['']]);
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
