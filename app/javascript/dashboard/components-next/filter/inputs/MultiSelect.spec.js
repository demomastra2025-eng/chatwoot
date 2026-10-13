import { flushPromises, mount } from '@vue/test-utils';
import MultiSelect from './MultiSelect.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key}:${params.searchTerm}` : key),
  }),
}));

const options = [
  { id: '501', name: 'Терапевт · 1' },
  { id: '502', name: 'Процедурный · 2' },
  { id: '503', name: 'Лаборатория' },
];

// Records the v-tooltip value on the element so specs can read it.
const setTooltip = (el, binding) =>
  el.setAttribute('data-tooltip', binding.value);

const mountSelect = (props = {}) =>
  mount(MultiSelect, {
    props: { modelValue: [], options, ...props },
    global: {
      directives: { tooltip: { mounted: setTooltip, updated: setTooltip } },
      stubs: {
        DropdownContainer: {
          template:
            '<div><slot name="trigger" :toggle="() => {}" /><slot /></div>',
        },
        DropdownBody: { template: '<div><slot /></div>' },
        DropdownSection: { template: '<section><slot /></section>' },
        DropdownItem: {
          template: '<div class="item"><slot name="label" /><slot /></div>',
        },
        Button: { template: '<button><slot name="icon" /><slot /></button>' },
        Icon: true,
      },
    },
  });

const optionNames = wrapper =>
  wrapper.findAll('.item').map(item => item.text());

describe('MultiSelect', () => {
  it('lists every option without a search box by default', () => {
    const wrapper = mountSelect();

    expect(wrapper.find('input').exists()).toBe(false);
    expect(optionNames(wrapper)).toEqual([
      'Терапевт · 1',
      'Процедурный · 2',
      'Лаборатория',
    ]);
  });

  it('filters the options by the search text when searchable', async () => {
    const wrapper = mountSelect({ searchable: true });

    await wrapper.find('input').setValue('лаб');

    expect(optionNames(wrapper)).toEqual(['Лаборатория']);

    await wrapper.find('input').setValue('');

    expect(optionNames(wrapper)).toHaveLength(3);
  });

  it('keeps selecting from the filtered list', async () => {
    const wrapper = mountSelect({ searchable: true });

    await wrapper.find('input').setValue('лаб');
    await wrapper.find('.item').trigger('click');

    expect(wrapper.emitted('update:modelValue')[0][0]).toEqual([
      { id: '503', name: 'Лаборатория' },
    ]);
  });

  it('tells when nothing matches the search text', async () => {
    const wrapper = mountSelect({ searchable: true });

    await wrapper.find('input').setValue('хирург');

    expect(optionNames(wrapper)).toEqual([
      'COMBOBOX.EMPTY_SEARCH_RESULTS:хирург',
    ]);
  });

  describe('selected chips', () => {
    const selectedChips = wrapper =>
      wrapper.findAll('button > div[data-tooltip]');

    it('shows the full label of every selected chip as a tooltip', () => {
      const wrapper = mountSelect({
        modelValue: [
          { id: '501', name: 'Терапевт · 1' },
          { id: '502', name: 'Процедурный · 2' },
        ],
      });

      const tooltips = selectedChips(wrapper).map(chip =>
        chip.attributes('data-tooltip')
      );

      expect(tooltips).toEqual(['Терапевт · 1', 'Процедурный · 2']);
    });

    it('keys chips by id so equal labels do not collide', async () => {
      const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
      const wrapper = mountSelect({ modelValue: options });
      // Vue only reports duplicate keys while patching, so swap the chips.
      const sameLabel = ['601', '602', '603'].map(id => ({
        id,
        name: 'Кабинет · 1',
      }));

      await wrapper.setProps({ modelValue: sameLabel });

      const duplicateKeyWarnings = warn.mock.calls.filter(args =>
        String(args[0]).includes('Duplicate keys')
      );
      warn.mockRestore();

      expect(duplicateKeyWarnings).toHaveLength(0);
      expect(wrapper.findAll('button span.truncate')).toHaveLength(3);
    });

    it('marks a deleted item in the chips', () => {
      const wrapper = mountSelect({
        modelValue: [
          { id: 1, name: 'Айгерим' },
          { id: 2, name: 'Контакт удалён', deleted: true },
        ],
      });

      const [normal, deleted] = selectedChips(wrapper);

      expect(normal.classes()).not.toContain('text-n-ruby-11');
      expect(deleted.classes()).toContain('text-n-ruby-11');
    });
  });

  describe('selected items that are not in the list', () => {
    it('lists them first so they can be unselected', async () => {
      const archived = { id: '999', name: '№ 999' };
      const wrapper = mountSelect({ modelValue: [archived, options[0]] });

      expect(optionNames(wrapper)).toEqual([
        '№ 999',
        'Терапевт · 1',
        'Процедурный · 2',
        'Лаборатория',
      ]);

      await wrapper.find('.item').trigger('click');

      expect(wrapper.emitted('update:modelValue')[0][0]).toEqual([
        { id: '501', name: 'Терапевт · 1' },
      ]);
    });

    it('does not list them among the search results', async () => {
      const wrapper = mountSelect({
        searchable: true,
        modelValue: [{ id: '999', name: '№ 999' }],
      });

      await wrapper.find('input').setValue('лаб');

      expect(optionNames(wrapper)).toEqual(['Лаборатория']);
    });
  });

  describe('searching on the server (fetchOptions)', () => {
    const found = (names, hasMore = false) => ({
      options: names.map((name, index) => ({
        id: index + 1,
        name,
        description: `+7701000000${index}`,
      })),
      hasMore,
    });

    const mountRemote = (fetchOptions, props = {}) =>
      mountSelect({ options: [], fetchOptions, ...props });

    const open = async wrapper => {
      await wrapper.find('button').trigger('click');
      await flushPromises();
    };

    const search = async (wrapper, text) => {
      await wrapper.find('input').setValue(text);
      await vi.advanceTimersByTimeAsync(300);
      await flushPromises();
    };

    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it('offers the search box and loads the first page only once opened', async () => {
      const fetchOptions = vi.fn().mockResolvedValue(found(['Айгерим']));
      const wrapper = mountRemote(fetchOptions, {
        searchPlaceholder: 'Имя или телефон',
      });

      expect(wrapper.find('input').attributes('placeholder')).toBe(
        'Имя или телефон'
      );
      expect(fetchOptions).not.toHaveBeenCalled();

      await open(wrapper);

      expect(fetchOptions).toHaveBeenCalledTimes(1);
      expect(fetchOptions).toHaveBeenCalledWith('', 1);
      expect(wrapper.findAll('.item')).toHaveLength(1);
    });

    it('falls back to the common search placeholder', () => {
      const wrapper = mountRemote(vi.fn());

      expect(wrapper.find('input').attributes('placeholder')).toBe(
        'COMBOBOX.SEARCH_PLACEHOLDER'
      );
    });

    it('shows the phone number under the name of every result', async () => {
      const wrapper = mountRemote(
        vi.fn().mockResolvedValue(found(['Айгерим', 'Берик']))
      );

      await open(wrapper);

      const rows = wrapper.findAll('.item');
      expect(rows.map(row => row.find('span span').text())).toEqual([
        'Айгерим',
        'Берик',
      ]);
      expect(rows.map(row => row.findAll('span span')[1].text())).toEqual([
        '+77010000000',
        '+77010000001',
      ]);
    });

    it('asks the server once the user stops typing, not on every key', async () => {
      const fetchOptions = vi
        .fn()
        .mockResolvedValueOnce(found(['Айгерим', 'Берик']))
        .mockResolvedValueOnce(found(['Берик']));
      const wrapper = mountRemote(fetchOptions);
      await open(wrapper);

      await wrapper.find('input').setValue('бе');
      await vi.advanceTimersByTimeAsync(200);
      await wrapper.find('input').setValue('бер');
      await vi.advanceTimersByTimeAsync(299);

      expect(fetchOptions).toHaveBeenCalledTimes(1);

      await vi.advanceTimersByTimeAsync(1);
      await flushPromises();

      expect(fetchOptions).toHaveBeenCalledTimes(2);
      expect(fetchOptions).toHaveBeenLastCalledWith('бер', 1);
      expect(
        wrapper.findAll('.item').map(row => row.find('span span').text())
      ).toEqual(['Берик']);
    });

    it('does not filter what the server found by the typed text again', async () => {
      const wrapper = mountRemote(
        vi
          .fn()
          .mockResolvedValueOnce(found(['Айгерим']))
          .mockResolvedValueOnce(found(['+7 701 123 45 67']))
      );
      await open(wrapper);

      await search(wrapper, '1234567');

      expect(wrapper.findAll('.item')).toHaveLength(1);
      expect(wrapper.text()).toContain('+7 701 123 45 67');
    });

    it('ignores a slow answer to an older search', async () => {
      let answerOlder;
      const older = new Promise(resolve => {
        answerOlder = resolve;
      });
      const fetchOptions = vi
        .fn()
        .mockResolvedValueOnce(found(['Первый']))
        .mockReturnValueOnce(older)
        .mockResolvedValueOnce(found(['Новый']));
      const wrapper = mountRemote(fetchOptions);
      await open(wrapper);

      await search(wrapper, 'а');
      await search(wrapper, 'ай');
      answerOlder(found(['Устаревший']));
      await flushPromises();

      expect(wrapper.text()).toContain('Новый');
      expect(wrapper.text()).not.toContain('Устаревший');
    });

    it('shows a loading row while the server answers', async () => {
      let answer;
      const wrapper = mountRemote(
        vi.fn().mockReturnValue(
          new Promise(resolve => {
            answer = resolve;
          })
        )
      );

      await wrapper.find('button').trigger('click');

      expect(wrapper.text()).toContain('DROPDOWN_MENU.SEARCHING');

      answer(found(['Айгерим']));
      await flushPromises();

      expect(wrapper.text()).not.toContain('DROPDOWN_MENU.SEARCHING');
    });

    it('tells when nothing is found, with and without a search text', async () => {
      const wrapper = mountRemote(vi.fn().mockResolvedValue(found([])));

      await open(wrapper);

      expect(optionNames(wrapper)).toEqual(['COMBOBOX.EMPTY_STATE']);

      await search(wrapper, 'хирург');

      expect(optionNames(wrapper)).toEqual([
        'COMBOBOX.EMPTY_SEARCH_RESULTS:хирург',
      ]);
    });

    it('pages through the results with a "show more" row', async () => {
      const fetchOptions = vi
        .fn()
        .mockResolvedValueOnce({
          options: [{ id: 1, name: 'Айгерим' }],
          hasMore: true,
        })
        .mockResolvedValueOnce({
          options: [
            { id: 1, name: 'Айгерим' },
            { id: 2, name: 'Берик' },
          ],
          hasMore: false,
        });
      const wrapper = mountRemote(fetchOptions);
      await open(wrapper);

      expect(optionNames(wrapper)).toEqual(['Айгерим', 'COMBOBOX.LOAD_MORE']);

      await wrapper.findAll('.item')[1].trigger('click');
      await flushPromises();

      expect(fetchOptions).toHaveBeenLastCalledWith('', 2);
      expect(optionNames(wrapper)).toEqual(['Айгерим', 'Берик']);
    });

    it('says so when the list cannot be loaded and retries when reopened', async () => {
      const fetchOptions = vi
        .fn()
        .mockRejectedValueOnce(new Error('Network Error'))
        .mockResolvedValueOnce(found(['Айгерим']));
      const wrapper = mountRemote(fetchOptions);

      await open(wrapper);

      expect(optionNames(wrapper)).toEqual(['COMBOBOX.LOAD_ERROR']);

      await open(wrapper);

      expect(fetchOptions).toHaveBeenCalledTimes(2);
      expect(wrapper.text()).toContain('Айгерим');
      expect(wrapper.text()).not.toContain('COMBOBOX.LOAD_ERROR');
    });

    it('selects a found item with its phone number and unselects it again', async () => {
      const wrapper = mountRemote(
        vi.fn().mockResolvedValue(found(['Айгерим', 'Берик']))
      );
      await open(wrapper);

      await wrapper.findAll('.item')[1].trigger('click');

      const chosen = [{ id: 2, name: 'Берик', description: '+77010000001' }];
      expect(wrapper.emitted('update:modelValue')[0][0]).toEqual(chosen);

      await wrapper.setProps({ modelValue: chosen });
      await wrapper.findAll('.item')[1].trigger('click');

      expect(wrapper.emitted('update:modelValue')[1][0]).toEqual([]);
    });

    it('keeps a selected contact that was deleted removable, first in the list', async () => {
      const gone = { id: 77, name: 'Контакт удалён (№ 77)', deleted: true };
      const wrapper = mountRemote(
        vi.fn().mockResolvedValue(found(['Айгерим'])),
        { modelValue: [gone], options: [gone] }
      );
      await open(wrapper);

      const [deletedRow] = wrapper.findAll('.item');
      expect(deletedRow.text()).toContain('Контакт удалён');
      expect(deletedRow.find('span').classes()).toContain('text-n-ruby-11');

      await deletedRow.trigger('click');

      expect(wrapper.emitted('update:modelValue')[0][0]).toEqual([]);
    });
  });
});
