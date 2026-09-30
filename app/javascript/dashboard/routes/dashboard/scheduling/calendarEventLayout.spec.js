import { describe, expect, it } from 'vitest';

import {
  CANCELLED_LANE_ZONE_PERCENT,
  buildTimelineEventLayout,
  resolveAppointmentCalendarTone,
  resolveEventDensity,
} from './calendarEventLayout';
import {
  APPOINTMENT_PROVIDER_REVIEW_COLOR,
  APPOINTMENT_STATUS_CALENDAR_TONES,
  APPOINTMENT_STATUS_ICON_CLASSES,
  APPOINTMENT_STATUS_PILL_CLASSES,
  APPOINTMENT_STATUS_VALUES,
} from './constants';

const at = (hours, minutes = 0) => hours * 60 + minutes;
const item = (id, start, end, cancelled = false) => ({
  cancelled,
  endMinute: end,
  id,
  startMinute: start,
});

describe('buildTimelineEventLayout', () => {
  it('gives a lone appointment the full column', () => {
    const layout = buildTimelineEventLayout([item(1, at(9), at(9, 30))]);

    expect(layout.get(1)).toEqual({ left: 0, width: 100 });
  });

  it('keeps back-to-back appointments full width (touching is not overlapping)', () => {
    const layout = buildTimelineEventLayout([
      item(1, at(9), at(9, 30)),
      item(2, at(9, 30), at(10)),
    ]);

    expect(layout.get(1)).toEqual({ left: 0, width: 100 });
    expect(layout.get(2)).toEqual({ left: 0, width: 100 });
  });

  it('splits live overlapping appointments into equal columns for the whole cluster', () => {
    // 1 overlaps 2 and 3; 2 and 3 do not overlap each other -> two lanes,
    // every event of the cluster is 50% wide.
    const layout = buildTimelineEventLayout([
      item(1, at(10), at(11)),
      item(2, at(10), at(10, 30)),
      item(3, at(10, 30), at(11)),
    ]);

    expect(layout.get(1)).toEqual({ left: 0, width: 50 });
    expect(layout.get(2)).toEqual({ left: 50, width: 50 });
    expect(layout.get(3)).toEqual({ left: 50, width: 50 });
  });

  it('uses the same lane width for chained overlaps', () => {
    const layout = buildTimelineEventLayout([
      item('a', at(9), at(10)),
      item('b', at(9, 30), at(10, 30)),
      item('c', at(10), at(11)),
      item('d', at(10, 15), at(10, 45)),
    ]);
    const widths = new Set(
      ['a', 'b', 'c', 'd'].map(id => layout.get(id).width)
    );

    expect(widths.size).toBe(1);
    expect([...widths][0]).toBeCloseTo(100 / 3, 2);
  });

  it('moves cancelled appointments into a narrow zone on the right', () => {
    // Owner screenshot: two cancelled bookings and one live visit at 10:30.
    const layout = buildTimelineEventLayout([
      item('cancelled-1', at(10, 30), at(11), true),
      item('cancelled-2', at(10, 30), at(11), true),
      item('live', at(10, 30), at(11)),
    ]);
    const liveWidth = 100 - CANCELLED_LANE_ZONE_PERCENT;

    expect(layout.get('live')).toEqual({ left: 0, width: liveWidth });
    expect(layout.get('cancelled-1')).toEqual({
      left: liveWidth,
      width: CANCELLED_LANE_ZONE_PERCENT / 2,
    });
    expect(layout.get('cancelled-2')).toEqual({
      left: liveWidth + CANCELLED_LANE_ZONE_PERCENT / 2,
      width: CANCELLED_LANE_ZONE_PERCENT / 2,
    });
  });

  it('keeps live cards the same width however many cancellations overlap them', () => {
    const one = buildTimelineEventLayout([
      item('live', at(12), at(12, 30)),
      item('x', at(12), at(12, 30), true),
    ]);
    const three = buildTimelineEventLayout([
      item('live', at(12, 30), at(13)),
      item('x', at(12, 30), at(13), true),
      item('y', at(12, 30), at(13), true),
      item('z', at(12, 30), at(13), true),
    ]);

    expect(one.get('live').width).toBe(three.get('live').width);
  });

  it('lets cancelled appointments use the whole column when nothing live overlaps', () => {
    const layout = buildTimelineEventLayout([
      item('x', at(16), at(16, 30), true),
      item('y', at(16), at(16, 30), true),
    ]);

    expect(layout.get('x')).toEqual({ left: 0, width: 50 });
    expect(layout.get('y')).toEqual({ left: 50, width: 50 });
  });

  it('ignores invalid items and treats zero-length ones as one minute', () => {
    const layout = buildTimelineEventLayout([
      null,
      { id: 'bad', startMinute: Number.NaN, endMinute: 10 },
      item('zero', at(9), at(9)),
      item('next', at(9, 1), at(9, 30)),
    ]);

    expect(layout.has('bad')).toBe(false);
    expect(layout.get('zero')).toEqual({ left: 0, width: 100 });
    expect(layout.get('next')).toEqual({ left: 0, width: 100 });
  });
});

describe('resolveEventDensity', () => {
  it('switches between two-line, one-line and tiny cards by height', () => {
    expect(resolveEventDensity(40)).toBe('regular');
    expect(resolveEventDensity(36)).toBe('regular');
    expect(resolveEventDensity(26)).toBe('compact');
    expect(resolveEventDensity(18)).toBe('compact');
    expect(resolveEventDensity(13)).toBe('tiny');
  });
});

describe('appointment status colours', () => {
  it('defines a calendar tone, icon class and pill for every status', () => {
    APPOINTMENT_STATUS_VALUES.forEach(status => {
      expect(APPOINTMENT_STATUS_CALENDAR_TONES[status]).toBeTruthy();
      expect(APPOINTMENT_STATUS_ICON_CLASSES).toHaveProperty(status);
      expect(APPOINTMENT_STATUS_PILL_CLASSES[status]).toBeTruthy();
    });
  });

  it('shows confirmed appointments in green and scheduled ones in blue', () => {
    expect(resolveAppointmentCalendarTone({ status: 'confirmed' })).toEqual({
      variant: 'solid',
      accent: '#12A594',
    });
    expect(resolveAppointmentCalendarTone({ status: 'scheduled' })).toEqual({
      variant: 'solid',
      accent: '#2563EB',
    });
    expect(APPOINTMENT_STATUS_ICON_CLASSES.confirmed).toBe('text-n-teal-11');
    expect(APPOINTMENT_STATUS_PILL_CLASSES.confirmed).toContain('n-teal');
  });

  it('mutes finished visits and outlines cancelled ones', () => {
    expect(
      resolveAppointmentCalendarTone({ status: 'completed' }).variant
    ).toBe('muted');
    expect(resolveAppointmentCalendarTone({ status: 'no_show' }).variant).toBe(
      'muted'
    );
    expect(
      resolveAppointmentCalendarTone({ status: 'cancelled' }).variant
    ).toBe('ghost');
    expect(
      resolveAppointmentCalendarTone({ status: 'scheduled', cancelled: true })
        .variant
    ).toBe('ghost');
  });

  it('flags MedElement bookings that need review in red', () => {
    expect(
      resolveAppointmentCalendarTone({ status: 'confirmed', needsReview: true })
    ).toEqual({ variant: 'solid', accent: APPOINTMENT_PROVIDER_REVIEW_COLOR });
  });

  it('can colour by resource for non-appointment calendars', () => {
    expect(
      resolveAppointmentCalendarTone({
        colorBy: 'resource',
        resourceColor: '#f97316',
        status: 'scheduled',
      })
    ).toEqual({ variant: 'solid', accent: '#f97316' });
    expect(
      resolveAppointmentCalendarTone({
        colorBy: 'resource',
        muted: true,
        cancelled: true,
        resourceColor: '#f97316',
      }).variant
    ).toBe('ghost');
  });

  it('falls back to the scheduled colour for unknown statuses', () => {
    expect(resolveAppointmentCalendarTone({ status: 'mystery' })).toEqual({
      variant: 'solid',
      accent: APPOINTMENT_STATUS_CALENDAR_TONES.scheduled.color,
    });
  });
});
