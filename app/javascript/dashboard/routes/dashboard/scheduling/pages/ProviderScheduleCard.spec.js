import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import ProviderScheduleCard from './ProviderScheduleCard.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) =>
      ({
        'SCHEDULING.RESOURCES.PROVIDER_SCHEDULE_TITLE': 'График из MedElement',
        'SCHEDULING.RESOURCES.PROVIDER_NOT_LOADED':
          'График MedElement пока не загружен.',
        'SCHEDULING.RESOURCES.PROVIDER_UPDATED': `Обновлено ${params.count} мин. назад`,
      })[key] || key,
  }),
}));

const loadedSchedule = () => ({
  checkedAt: new Date(Date.now() - 5 * 60 * 1000).toISOString(),
  differsFromTemplate: true,
  days: [
    {
      date: '2026-04-16',
      status: 'confirmed',
      windows: [
        { start: '09:00', end: '09:15' },
        { start: '09:15', end: '09:30' },
      ],
    },
  ],
});

const mountCard = schedule =>
  mount(ProviderScheduleCard, { props: { schedule } });

describe('ProviderScheduleCard', () => {
  it('shows a compact MedElement schedule indicator without rendering slot lists or expand buttons', () => {
    const wrapper = mountCard(loadedSchedule());

    expect(wrapper.text()).toContain('График из MedElement');
    expect(wrapper.text()).toContain('Обновлено 5 мин. назад');
    expect(wrapper.text()).not.toContain('09:00–09:15');
    expect(wrapper.find('[data-testid="provider-schedule-day"]').exists()).toBe(
      false
    );
    expect(wrapper.find('button').exists()).toBe(false);
  });

  it('explains when no provider schedule has loaded yet', () => {
    const wrapper = mountCard({ checkedAt: null, days: [] });

    expect(wrapper.text()).toContain('График из MedElement');
    expect(wrapper.text()).toContain('График MedElement пока не загружен.');
    expect(wrapper.find('button').exists()).toBe(false);
  });
});
