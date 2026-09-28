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
      date: '2026-03-10',
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
      day: new Date(2026, 2, 9),
      preferredResourceIds: [12],
    });
    const stats = buildMonthStats([
      new Date(2026, 2, 9),
      new Date(2026, 2, 10),
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

  it('indexes instants by workspace day across browser day and DST boundaries', () => {
    const workspaceTimezone = ref('Asia/Almaty');
    const lateSlot = {
      resourceId: 12,
      startsAt: '2026-09-27T19:00:00.000Z',
      endsAt: '2026-09-27T19:30:00.000Z',
    };
    const indexes = useSchedulingCalendarIndexes({
      appointments: ref([{ startsAt: lateSlot.startsAt }]),
      holidays: ref([]),
      resources,
      slots: ref([lateSlot]),
      timeOffs: ref([{ startsAt: lateSlot.startsAt }]),
      workspaceTimezone,
    });
    const sunday = new Date(2026, 8, 27);
    const monday = new Date(2026, 8, 28);

    expect(indexes.findFirstAvailableSlotForDay({ day: monday })).toEqual(
      lateSlot
    );
    expect(
      indexes.availableCandidatesByDayMinuteKey.value.get('2026-09-28|0')
    ).toEqual([lateSlot]);
    expect(indexes.buildMonthStats([sunday, monday]).get('2026-09-28')).toEqual(
      {
        appointments: 1,
        availableSlots: 1,
        holidays: 0,
        timeOff: 1,
      }
    );
    expect(indexes.buildMonthStats([sunday, monday]).get('2026-09-27')).toEqual(
      {
        appointments: 0,
        availableSlots: 0,
        holidays: 0,
        timeOff: 0,
      }
    );

    workspaceTimezone.value = 'UTC';
    expect(indexes.findFirstAvailableSlotForDay({ day: sunday })).toEqual(
      lateSlot
    );
    expect(
      indexes.availableCandidatesByDayMinuteKey.value.get('2026-09-27|1140')
    ).toEqual([lateSlot]);
  });

  it('keeps a workspace-Monday slot on Monday through the browser DST switch', () => {
    const slot = {
      resourceId: 12,
      startsAt: '2026-03-08T22:30:00.000Z',
      endsAt: '2026-03-08T23:00:00.000Z',
    };
    const indexes = useSchedulingCalendarIndexes({
      appointments: ref([]),
      holidays: ref([]),
      resources,
      slots: ref([slot]),
      timeOffs: ref([]),
      workspaceTimezone: ref('Asia/Almaty'),
    });
    const monday = new Date(2026, 2, 9);

    expect(
      indexes.buildMonthStats([monday]).get('2026-03-09').availableSlots
    ).toBe(1);
    expect(indexes.findFirstAvailableSlotForDay({ day: monday })).toEqual(slot);
    expect(
      indexes.availableCandidatesByDayMinuteKey.value.get('2026-03-09|210')
    ).toEqual([slot]);
  });

  it('indexes a workspace 02:30 slot during the browser spring-forward gap', () => {
    const slot = {
      resourceId: 12,
      startsAt: '2026-03-07T21:30:00.000Z',
      endsAt: '2026-03-07T22:00:00.000Z',
    };
    const indexes = useSchedulingCalendarIndexes({
      appointments: ref([]),
      holidays: ref([]),
      resources,
      slots: ref([slot]),
      timeOffs: ref([]),
      workspaceTimezone: ref('Asia/Almaty'),
    });
    expect(
      indexes.availableCandidatesByDayMinuteKey.value.get('2026-03-08|150')
    ).toEqual([slot]);
    expect(
      indexes.availableCandidatesByDayMinuteKey.value.get('2026-03-08|210')
    ).toBeUndefined();
    expect(
      indexes.findFirstAvailableSlotForDay({ day: new Date(2026, 2, 8) })
    ).toEqual(slot);
    expect(indexes.isRangeAvailable({ resourceId: 12, ...slot })).toBe(true);
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
