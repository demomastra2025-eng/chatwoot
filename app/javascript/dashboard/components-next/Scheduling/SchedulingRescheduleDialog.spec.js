import { afterEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import SchedulingAvailabilityAPI from 'dashboard/api/scheduling/availability';
import SchedulingRescheduleDialog from './SchedulingRescheduleDialog.vue';

vi.mock('vue-i18n', async importOriginal => ({
  ...(await importOriginal()),
  useI18n: () => ({ t: key => key, locale: { value: 'ru' } }),
}));
vi.mock('dashboard/api/scheduling/availability', () => ({
  default: { show: vi.fn() },
}));

afterEach(() => vi.useRealTimers());

describe('SchedulingRescheduleDialog', () => {
  it('uses availability windows and keeps the appointment duration', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-27T09:00:00Z'));
    SchedulingAvailabilityAPI.show.mockResolvedValue({
      data: {
        payload: {
          state: 'ok',
          windows: [
            {
              starts_at: '2026-10-29T09:30:00Z',
              ends_at: '2026-10-29T11:00:00Z',
            },
          ],
        },
      },
    });
    const wrapper = mount(SchedulingRescheduleDialog, {
      props: {
        appointment: {
          id: 15,
          resourceId: 7,
          durationMin: 45,
          startsAt: '2026-10-29T08:00:00Z',
        },
        resources: [{ id: 7, name: 'Врач' }],
        timezone: 'Asia/Almaty',
      },
      global: {
        stubs: {
          Dialog: {
            template: '<div><slot /></div>',
            methods: { open() {}, close() {} },
          },
          Button: {
            props: ['label', 'disabled'],
            emits: ['click'],
            template:
              '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
          },
          SchedulingSelectField: {
            props: ['modelValue', 'options'],
            template:
              '<select><option v-for="option in options" :key="option.value">{{ option.label }}</option></select>',
          },
        },
      },
    });
    wrapper.vm.open();
    await flushPromises();

    expect(SchedulingAvailabilityAPI.show).toHaveBeenCalledWith({
      date: '2026-10-29',
      duration_min: 45,
      resource_id: 7,
    });
    const slot = wrapper
      .findAll('button')
      .find(button => button.text() === '14:30');
    expect(slot).toBeTruthy();
    await slot.trigger('click');
    await wrapper
      .findAll('button')
      .find(button =>
        button.text().includes('SCHEDULING.RESCHEDULE.CONFIRM_AT')
      )
      .trigger('click');
    expect(wrapper.emitted('select')[0][0]).toEqual({
      resourceId: 7,
      startsAt: '2026-10-29T14:30',
      endsAt: '2026-10-29T15:15',
    });
  });
});
