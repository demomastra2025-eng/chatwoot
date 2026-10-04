import { mount } from '@vue/test-utils';
import DsStatusDot from '../DsStatusDot.vue';

describe('DsStatusDot', () => {
  it.each([
    ['good', 'OK', 'bg-n-status-good'],
    ['warn', 'Attention', 'bg-n-status-warn'],
    ['bad', 'Error', 'bg-n-status-bad'],
    ['neutral', 'No data', 'bg-n-slate-9'],
  ])('renders a %s dot together with a word', (status, word, dotClass) => {
    const wrapper = mount(DsStatusDot, { props: { status } });
    const dot = wrapper.find('[data-test-id="ds-status-dot"]');

    expect(dot.exists()).toBe(true);
    expect(dot.classes()).toContain(dotClass);
    expect(dot.attributes('aria-hidden')).toBe('true');
    expect(wrapper.text()).toBe(word);
  });

  it('prefers a passed label over the default word', () => {
    const wrapper = mount(DsStatusDot, {
      props: { status: 'warn', label: 'Storage at 88%' },
    });

    expect(wrapper.text()).toBe('Storage at 88%');
    expect(wrapper.find('[data-test-id="ds-status-dot"]').exists()).toBe(true);
  });

  it('never renders colour alone', () => {
    ['good', 'warn', 'bad', 'neutral'].forEach(status => {
      const wrapper = mount(DsStatusDot, { props: { status, label: '' } });
      expect(wrapper.text().trim().length).toBeGreaterThan(0);
    });
  });
});
