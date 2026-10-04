import { mount } from '@vue/test-utils';
import DsStatGroup from '../DsStatGroup.vue';

const items = [
  { key: 'accounts', label: 'Active accounts', value: '48', note: '+2' },
  { key: 'calls', label: 'Calls', value: '2,944' },
  { key: 'missed', label: 'Missed', value: '4.7%' },
];

describe('DsStatGroup', () => {
  it('renders all indicators inside ONE card', () => {
    const wrapper = mount(DsStatGroup, { props: { items } });

    expect(wrapper.findAll('dl')).toHaveLength(1);
    expect(wrapper.classes()).toContain('rounded-ds-card');
    expect(wrapper.findAll('[data-test-id="ds-stat"]')).toHaveLength(3);
    expect(wrapper.attributes('style')).toContain('--ds-stat-columns: 3');
  });

  it('separates indicators with thin vertical dividers, not tiles', () => {
    const wrapper = mount(DsStatGroup, { props: { items } });
    const stat = wrapper.find('[data-test-id="ds-stat"]');

    expect(stat.classes()).toContain('md:border-e');
    expect(stat.classes()).not.toContain('rounded-ds-card');
    expect(stat.classes().some(name => name.startsWith('bg-'))).toBe(false);
  });

  it('puts the muted caption above the big number', () => {
    const wrapper = mount(DsStatGroup, { props: { items } });
    const [caption, value, note] = wrapper
      .find('[data-test-id="ds-stat"]')
      .findAll('dt, dd');

    expect(caption.text()).toBe('Active accounts');
    expect(caption.classes()).toEqual(
      expect.arrayContaining(['text-ds-caption', 'text-n-slate-11'])
    );
    expect(value.text()).toBe('48');
    expect(value.classes()).toContain('text-ds-figure');
    expect(note.text()).toBe('+2');
  });

  it('supports value and note slots', () => {
    const wrapper = mount(DsStatGroup, {
      props: { items: [{ label: 'Storage', value: 412 }] },
      slots: {
        value: '<template #value="{ item }">{{ item.value }} GB</template>',
        note: '<template #note>of 600 GB</template>',
      },
    });

    expect(wrapper.text()).toContain('412 GB');
    expect(wrapper.text()).toContain('of 600 GB');
  });
});
