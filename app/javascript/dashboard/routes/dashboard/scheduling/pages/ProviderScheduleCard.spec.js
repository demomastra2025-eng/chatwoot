import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import ProviderScheduleCard from './ProviderScheduleCard.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, values) => {
      const labels = {
        'SCHEDULING.RESOURCES.PROVIDER_SCHEDULE_TITLE': 'График из MedElement',
        'SCHEDULING.RESOURCES.PROVIDER_NOT_LOADED':
          'График MedElement пока не загружен.',
        'SCHEDULING.RESOURCES.PROVIDER_UPDATED': `Обновлено ${values?.count} минут назад`,
        'SCHEDULING.RESOURCES.PROVIDER_DAY_OFF': 'Нет рабочих часов',
        'SCHEDULING.RESOURCES.PROVIDER_UNVERIFIED':
          'Данные пока не подтверждены',
        'SCHEDULING.RESOURCES.PROVIDER_DIFFERS':
          'График отличается от местных правил расписания.',
        'SCHEDULING.RESOURCES.PROVIDER_SHOW_SCHEDULE': 'Показать график',
        'SCHEDULING.RESOURCES.PROVIDER_HIDE_SCHEDULE': 'Скрыть график',
      };
      return labels[key];
    },
  }),
}));

const loadedSchedule = () => ({
  checkedAt: new Date(Date.now() - 5 * 60000).toISOString(),
  differsFromTemplate: true,
  days: [
    { date: '2026-10-07', status: 'empty_confirmed', windows: [] },
    {
      date: '2026-10-08',
      status: 'confirmed',
      windows: [{ start: '10:00', end: '12:00' }],
    },
    { date: '2026-10-09', status: 'unverified', windows: [] },
  ],
});

const mountCard = schedule => mount(ProviderScheduleCard, { props: { schedule } });
const dayRows = wrapper =>
  wrapper.findAll('[data-testid="provider-schedule-day"]');

describe('ProviderScheduleCard', () => {
  it('shows the update, difference, and next working hours while collapsed', () => {
    const wrapper = mountCard(loadedSchedule());
    const toggle = wrapper.get('button');

    expect(dayRows(wrapper)).toHaveLength(0);
    expect(wrapper.text()).toContain('10:00–12:00');
    expect(wrapper.text()).toContain('Обновлено 5 минут назад');
    expect(wrapper.text()).not.toContain('Нет рабочих часов');
    expect(wrapper.text()).toContain(
      'График отличается от местных правил расписания.'
    );
    expect(toggle.text()).toBe('Показать график');
    expect(toggle.attributes('aria-expanded')).toBe('false');
  });

  it('shows every day on expand and hides them on collapse', async () => {
    const wrapper = mountCard(loadedSchedule());
    const toggle = wrapper.get('button');

    await toggle.trigger('click');

    expect(dayRows(wrapper)).toHaveLength(3);
    expect(wrapper.text()).toContain('10:00–12:00');
    expect(wrapper.text()).toContain('Нет рабочих часов');
    expect(wrapper.text()).toContain('Данные пока не подтверждены');
    expect(toggle.text()).toBe('Скрыть график');
    expect(toggle.attributes('aria-expanded')).toBe('true');

    await toggle.trigger('click');

    expect(dayRows(wrapper)).toHaveLength(0);
    expect(toggle.text()).toBe('Показать график');
    expect(toggle.attributes('aria-expanded')).toBe('false');
  });

  it('starts collapsed again when the card is reopened', async () => {
    const firstCard = mountCard(loadedSchedule());
    await firstCard.get('button').trigger('click');
    firstCard.unmount();

    const reopenedCard = mountCard(loadedSchedule());
    expect(dayRows(reopenedCard)).toHaveLength(0);
    expect(reopenedCard.get('button').attributes('aria-expanded')).toBe(
      'false'
    );
  });

  it('explains when no provider schedule has loaded', () => {
    const wrapper = mountCard({ checkedAt: null, days: [] });

    expect(wrapper.text()).toContain('График MedElement пока не загружен.');
    expect(wrapper.find('button').exists()).toBe(false);
  });

  it('does not offer a toggle when the loaded schedule has no days', () => {
    const wrapper = mountCard({ checkedAt: new Date().toISOString(), days: [] });

    expect(wrapper.find('button').exists()).toBe(false);
  });
});
