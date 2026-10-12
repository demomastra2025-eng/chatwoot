import { mount } from '@vue/test-utils';
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
  });
});
