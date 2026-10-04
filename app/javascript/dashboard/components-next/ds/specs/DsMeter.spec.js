import { mount } from '@vue/test-utils';
import DsMeter from '../DsMeter.vue';

describe('DsMeter', () => {
  it('is a 4px meter with an accessible value', () => {
    const wrapper = mount(DsMeter, { props: { value: 42, label: 'Storage' } });
    const meter = wrapper.find('[role="meter"]');

    expect(meter.classes()).toContain('h-1');
    expect(meter.attributes('aria-valuenow')).toBe('42');
    expect(meter.attributes('aria-valuetext')).toBe('42%');
    expect(meter.attributes('aria-label')).toBe('Storage');
    expect(
      wrapper.find('[data-test-id="ds-meter-fill"]').attributes('style')
    ).toContain('width: 42%');
    expect(wrapper.text()).toBe('42%');
  });

  it('converts value and max to a clamped percentage', () => {
    const half = mount(DsMeter, { props: { value: 300, max: 600 } });
    const over = mount(DsMeter, { props: { value: 900, max: 600 } });
    const empty = mount(DsMeter, { props: { value: 5, max: 0 } });

    expect(half.find('[role="meter"]').attributes('aria-valuenow')).toBe('50');
    expect(over.find('[role="meter"]').attributes('aria-valuenow')).toBe('100');
    expect(empty.find('[role="meter"]').attributes('aria-valuenow')).toBe('0');
  });

  it.each([
    [40, 'accent', 'bg-n-brand'],
    [85, 'warn', 'bg-n-status-warn'],
    [97, 'bad', 'bg-n-status-bad'],
  ])('auto tone at %i%% is %s', (value, tone, fillClass) => {
    const wrapper = mount(DsMeter, { props: { value, tone: 'auto' } });

    expect(wrapper.attributes('data-tone')).toBe(tone);
    expect(wrapper.find('[data-test-id="ds-meter-fill"]').classes()).toContain(
      fillClass
    );
  });

  it('can hide the printed value', () => {
    const wrapper = mount(DsMeter, { props: { value: 10, showValue: false } });
    expect(wrapper.text()).toBe('');
  });
});
