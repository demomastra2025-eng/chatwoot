import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import SchedulingAvailabilityPicker from './SchedulingAvailabilityPicker.vue';

const { t } = vi.hoisted(() => ({ t: vi.fn(key => key) }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t }) }));
const first = {
  starts_at: '2026-10-10T09:00:00+05:00',
  ends_at: '2026-10-10T09:45:00+05:00',
};
const second = {
  starts_at: '2026-10-10T11:00:00+05:00',
  ends_at: '2026-10-10T11:45:00+05:00',
};

describe('SchedulingAvailabilityPicker', () => {
  beforeEach(() => vi.clearAllMocks());

  it('shows equal grid buttons in ascending order with only start times and the chosen state', async () => {
    const wrapper = mount(SchedulingAvailabilityPicker, {
      props: {
        state: 'ok',
        windows: [second, first],
        selectedStartsAt: '2026-10-10T06:00:00Z',
      },
    });
    const buttons = wrapper.findAll('button');
    expect(buttons.map(button => button.text())).toEqual(['09:00', '11:00']);
    expect(buttons.map(button => button.attributes('aria-pressed'))).toEqual([
      'false',
      'true',
    ]);
    expect(
      buttons.every(
        button =>
          button.classes().includes('h-9') &&
          button.classes().includes('w-full')
      )
    ).toBe(true);
    expect(buttons[0].element.parentElement.classList.contains('grid')).toBe(
      true
    );
    expect(buttons[1].classes()).toContain('border-n-brand');
    await buttons[0].trigger('click');
    expect(wrapper.emitted('select')).toEqual([[first]]);
  });

  it.each([
    ['closed_day', 'EMPTY'],
    ['schedule_not_confirmed', 'NOT_CONFIRMED'],
    ['provider_unavailable', 'UNAVAILABLE'],
  ])('distinguishes %s and never offers unknown time', (state, key) => {
    const wrapper = mount(SchedulingAvailabilityPicker, {
      props: { state, windows: [first] },
    });
    expect(wrapper.findAll('button')).toHaveLength(0);
    expect(wrapper.find('[role="status"]').text()).toBe(
      `SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.${key}`
    );
  });

  it('offers a button for a verified date while keeping the original empty day selected', async () => {
    const wrapper = mount(SchedulingAvailabilityPicker, {
      props: {
        date: '2026-10-10',
        state: 'closed_day',
        nearestState: 'found',
        nearestDate: '2026-10-12',
        emptyDate: '2026-10-10',
        searchThrough: '2026-11-10',
      },
    });
    expect(wrapper.find('[role="status"]').text()).toBe(
      'SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.NEAREST_CONFIRMED'
    );
    expect(t).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.NEAREST_CONFIRMED',
      { date: '2026-10-10', nearestDate: '2026-10-12', through: '2026-11-10' }
    );
    expect(wrapper.find('input[type="date"]').element.value).toBe('2026-10-10');
    const buttons = wrapper.findAll('button');
    expect(buttons).toHaveLength(1);
    expect(buttons[0].text()).toContain('2026-10-12');
    expect(wrapper.emitted('showNearest')).toBeUndefined();
    await buttons[0].trigger('click');
    expect(wrapper.emitted('showNearest')).toEqual([[]]);
    expect(wrapper.emitted('update:date')).toBeUndefined();
    expect(wrapper.emitted('select')).toBeUndefined();
    expect(wrapper.find('input[type="date"]').element.value).toBe('2026-10-10');
    await wrapper.setProps({
      date: '2026-10-12',
      state: 'ok',
      windows: [first],
      nearestState: '',
      nearestDate: '',
    });
    expect(wrapper.findAll('button').map(button => button.text())).toEqual([
      '09:00',
    ]);
  });
});
