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
      };
      return labels[key];
    },
  }),
}));

describe('ProviderScheduleCard', () => {
  it('renders real hours and the template difference', () => {
    const wrapper = mount(ProviderScheduleCard, {
      props: {
        schedule: {
          checkedAt: new Date(Date.now() - 5 * 60000).toISOString(),
          differsFromTemplate: true,
          days: [
            {
              date: '2026-10-07',
              status: 'confirmed',
              windows: [{ start: '10:00', end: '12:00' }],
            },
            { date: '2026-10-08', status: 'empty_confirmed', windows: [] },
          ],
        },
      },
    });

    expect(wrapper.text()).toContain('10:00–12:00');
    expect(wrapper.text()).toContain('Обновлено 5 минут назад');
    expect(wrapper.text()).toContain('Нет рабочих часов');
    expect(wrapper.text()).toContain(
      'График отличается от местных правил расписания.'
    );
  });

  it('explains when no provider schedule has loaded', () => {
    const wrapper = mount(ProviderScheduleCard, {
      props: { schedule: { checkedAt: null, days: [] } },
    });

    expect(wrapper.text()).toContain('График MedElement пока не загружен.');
  });
});
