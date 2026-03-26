import { ref } from 'vue';

import { useSchedulingCalendarIndexes } from './useSchedulingCalendarIndexes';

describe('useSchedulingCalendarIndexes', () => {
  const resources = ref([
    {
      id: 12,
      name: 'Dr. Kim',
      slotDurationMin: 30,
    },
  ]);

  const holidays = ref([
    {
      date: '2026-03-10T00:00:00.000Z',
      title: 'Holiday',
      workingDayOverride: false,
    },
  ]);

  const appointments = ref([
    {
      id: 1,
      resourceId: 12,
      startsAt: '2026-03-09T09:00:00.000Z',
      endsAt: '2026-03-09T09:30:00.000Z',
    },
  ]);

  const slots = ref([
    {
      resourceId: 12,
      startsAt: '2026-03-09T10:00:00.000Z',
      endsAt: '2026-03-09T10:30:00.000Z',
    },
    {
      resourceId: 12,
      startsAt: '2026-03-09T10:05:00.000Z',
      endsAt: '2026-03-09T10:35:00.000Z',
    },
  ]);

  const timeOffs = ref([
    {
      resourceId: 12,
      startsAt: '2026-03-09T15:00:00.000Z',
      endsAt: '2026-03-09T16:00:00.000Z',
    },
  ]);

  it('checks whether a moved or resized range still fits into available slots', () => {
    const { isRangeAvailable } = useSchedulingCalendarIndexes({
      appointments,
      holidays,
      resources,
      slots,
      timeOffs,
    });

    expect(
      isRangeAvailable({
        resourceId: 12,
        startsAt: '2026-03-09T10:05:00.000Z',
        endsAt: '2026-03-09T10:25:00.000Z',
      })
    ).toBe(true);

    expect(
      isRangeAvailable({
        resourceId: 12,
        startsAt: '2026-03-09T10:40:00.000Z',
        endsAt: '2026-03-09T11:10:00.000Z',
      })
    ).toBe(false);
  });

  it('picks the first available slot for a day and builds month stats', () => {
    const { buildMonthStats, findFirstAvailableSlotForDay } =
      useSchedulingCalendarIndexes({
        appointments,
        holidays,
        resources,
        slots,
        timeOffs,
      });

    const slot = findFirstAvailableSlotForDay({
      day: new Date('2026-03-09T00:00:00.000Z'),
      preferredResourceIds: [12],
    });
    const stats = buildMonthStats([
      new Date('2026-03-09T00:00:00.000Z'),
      new Date('2026-03-10T00:00:00.000Z'),
    ]);

    expect(slot).toMatchObject({
      resourceId: 12,
      startsAt: '2026-03-09T10:00:00.000Z',
    });

    expect(stats.get('2026-03-09')).toEqual({
      appointments: 1,
      availableSlots: 2,
      holidays: 0,
      timeOff: 1,
    });

    expect(stats.get('2026-03-10')).toEqual({
      appointments: 0,
      availableSlots: 0,
      holidays: 1,
      timeOff: 0,
    });
  });

  it('derives the calendar step from the smallest visible resource slot', () => {
    const mixedResources = ref([
      {
        id: 12,
        name: 'Dr. Kim',
        slotDurationMin: 30,
      },
      {
        id: 14,
        name: 'Dr. Noor',
        slotDurationMin: 15,
      },
    ]);

    const { slotStepMin } = useSchedulingCalendarIndexes({
      appointments,
      holidays,
      resources: mixedResources,
      slots,
      timeOffs,
    });

    expect(slotStepMin.value).toBe(15);
  });
});
