import {
  APPOINTMENT_PROVIDER_REVIEW_COLOR,
  APPOINTMENT_STATUS_CALENDAR_TONES,
} from './constants';

// Share of an overlap cluster's width given to cancelled appointments when the
// cluster also holds live ones. Fixed (not per count) so live cards keep one of
// two widths across the day instead of shrinking cluster by cluster.
export const CANCELLED_LANE_ZONE_PERCENT = 28;

// Card heights (px) at which the card switches layout: two lines (name, then
// service/specialist), one line, or a tiny one-line strip.
export const EVENT_DENSITY_REGULAR_MIN_PX = 36;
export const EVENT_DENSITY_COMPACT_MIN_PX = 18;

export const resolveEventDensity = heightPx => {
  if (heightPx >= EVENT_DENSITY_REGULAR_MIN_PX) return 'regular';
  if (heightPx >= EVENT_DENSITY_COMPACT_MIN_PX) return 'compact';
  return 'tiny';
};

const roundPercent = value => Math.round(value * 1000) / 1000;

// Greedy interval colouring: each item (sorted by start) takes the first lane
// that is free again at its start. Returns the lane count.
const assignLanes = items => {
  const laneEnds = [];

  items.forEach(item => {
    let lane = laneEnds.findIndex(end => end <= item.startMinute);
    if (lane === -1) {
      lane = laneEnds.length;
      laneEnds.push(item.endMinute);
    } else {
      laneEnds[lane] = item.endMinute;
    }
    item.lane = lane;
  });

  return laneEnds.length;
};

const splitIntoClusters = items => {
  const clusters = [];
  let current = null;
  let clusterEnd = -Infinity;

  items.forEach(item => {
    if (current && item.startMinute < clusterEnd) {
      current.push(item);
      clusterEnd = Math.max(clusterEnd, item.endMinute);
      return;
    }

    current = [item];
    clusters.push(current);
    clusterEnd = item.endMinute;
  });

  return clusters;
};

/**
 * Horizontal layout for the events of ONE timeline column (a specialist's day,
 * or a whole day in the shared week view).
 *
 * Events that overlap (directly or through a chain) form a cluster; every
 * event of a cluster gets the same lane width, so columns line up instead of
 * each event picking its own fraction. Cancelled events never take a live
 * lane: they share a narrow zone on the right of their cluster (or the whole
 * width when nothing live overlaps them).
 *
 * @param {Array<{id, startMinute, endMinute, cancelled}>} items
 * @returns {Map<id, {left, width}>} left/width in percent of the column.
 */
export const buildTimelineEventLayout = items => {
  const normalized = (items || [])
    .filter(
      item =>
        item &&
        Number.isFinite(item.startMinute) &&
        Number.isFinite(item.endMinute)
    )
    .map(item => ({
      cancelled: Boolean(item.cancelled),
      endMinute: Math.max(item.endMinute, item.startMinute + 1),
      id: item.id,
      startMinute: item.startMinute,
    }))
    .sort(
      (left, right) =>
        left.startMinute - right.startMinute ||
        right.endMinute - left.endMinute ||
        String(left.id).localeCompare(String(right.id))
    );

  const layout = new Map();

  splitIntoClusters(normalized).forEach(cluster => {
    const live = cluster.filter(item => !item.cancelled);
    const cancelled = cluster.filter(item => item.cancelled);
    const liveLanes = assignLanes(live);
    const cancelledLanes = assignLanes(cancelled);

    let cancelledZone = 0;
    if (cancelledLanes) {
      cancelledZone = liveLanes ? CANCELLED_LANE_ZONE_PERCENT : 100;
    }
    const liveZone = 100 - cancelledZone;

    live.forEach(item => {
      const width = liveZone / liveLanes;
      layout.set(item.id, {
        left: roundPercent(width * item.lane),
        width: roundPercent(width),
      });
    });

    cancelled.forEach(item => {
      const width = cancelledZone / cancelledLanes;
      layout.set(item.id, {
        left: roundPercent(liveZone + width * item.lane),
        width: roundPercent(width),
      });
    });
  });

  return layout;
};

/**
 * Card look for an appointment on the calendar.
 *
 * @returns {{variant: 'solid'|'muted'|'ghost', accent: string}}
 */
export const resolveAppointmentCalendarTone = ({
  cancelled = false,
  colorBy = 'status',
  muted = false,
  needsReview = false,
  resourceColor = '',
  status = 'scheduled',
} = {}) => {
  const tones = APPOINTMENT_STATUS_CALENDAR_TONES;

  if (cancelled || status === 'cancelled') {
    return { variant: 'ghost', accent: tones.cancelled.color };
  }

  if (muted || tones[status]?.variant === 'muted') {
    return {
      variant: 'muted',
      accent: tones[status]?.color || tones.completed.color,
    };
  }

  if (needsReview) {
    return { variant: 'solid', accent: APPOINTMENT_PROVIDER_REVIEW_COLOR };
  }

  if (colorBy === 'resource') {
    return {
      variant: 'solid',
      accent: resourceColor || tones.scheduled.color,
    };
  }

  return {
    variant: 'solid',
    accent: (tones[status] || tones.scheduled).color,
  };
};
