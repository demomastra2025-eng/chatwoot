import {
  buildCalendarRange,
  deriveVisibleMinuteWindow,
  getServicePriceForResource,
  shiftAnchorDate,
} from './helpers';

describe('scheduling helpers', () => {
  it('builds a week range anchored to Monday', () => {
    const { from, to } = buildCalendarRange('week', '2026-03-11T08:00:00.000Z');

    expect(from.toISOString()).toBe('2026-03-09T00:00:00.000Z');
    expect(to.toISOString()).toBe('2026-03-15T23:59:59.999Z');
  });

  it('shifts list view by two weeks', () => {
    const nextDate = shiftAnchorDate('list', '2026-03-09T00:00:00.000Z', 1);

    expect(nextDate.toISOString()).toBe('2026-03-23T00:00:00.000Z');
  });

  it('shifts kanban view by two weeks', () => {
    const nextDate = shiftAnchorDate('kanban', '2026-03-09T00:00:00.000Z', 1);

    expect(nextDate.toISOString()).toBe('2026-03-23T00:00:00.000Z');
  });

  it('derives a visible minute window from rules and appointments', () => {
    const window = deriveVisibleMinuteWindow({
      appointments: [
        {
          startsAt: '2026-03-09T06:30:00.000Z',
          endsAt: '2026-03-09T07:15:00.000Z',
        },
      ],
      columns: [
        {
          date: new Date('2026-03-09T00:00:00.000Z'),
          resourceId: 10,
        },
      ],
      workRules: [
        {
          active: true,
          endMinute: 18 * 60,
          resourceId: 10,
          startMinute: 9 * 60,
          weekday: 1,
        },
      ],
      workdayOverrides: [],
    });

    expect(window).toEqual({
      endMinute: 1200,
      startMinute: 300,
    });
  });

  it('prefers a resource-specific active price over the base price', () => {
    const price = getServicePriceForResource(
      {
        basePrice: 7000,
        prices: [
          { active: false, price: 9000, resourceId: 12 },
          { active: true, price: 12000, resourceId: 15 },
        ],
      },
      15
    );

    expect(price).toBe(12000);
  });
});
