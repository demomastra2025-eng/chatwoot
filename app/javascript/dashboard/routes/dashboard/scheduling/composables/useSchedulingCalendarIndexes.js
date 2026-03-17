import { computed } from 'vue';

import { MINUTE_STEP } from '../constants';
import {
  dayMatchesHoliday,
  formatDateKey,
  minuteOfDayFromDate,
  toDate,
} from '../helpers';

const createMonthStat = () => ({
  appointments: 0,
  availableSlots: 0,
  holidays: 0,
  timeOff: 0,
});

const dayMinuteKey = (dateKey, minute) => `${dateKey}|${minute}`;

const pushMapArray = (map, key, value) => {
  const current = map.get(key);
  if (current) {
    current.push(value);
    return;
  }

  map.set(key, [value]);
};

export const useSchedulingCalendarIndexes = ({
  appointments,
  holidays,
  resources,
  slots,
  timeOffs,
}) => {
  const slotStepMin = computed(() => {
    if (!resources.value.length) {
      return MINUTE_STEP;
    }

    return resources.value.reduce((smallestStep, resource) => {
      const rawStep = Math.round(Number(resource.slotDurationMin) || 0);
      const normalizedStep = Math.max(MINUTE_STEP, rawStep || MINUTE_STEP);
      return Math.min(smallestStep, normalizedStep);
    }, 60);
  });

  const slotMap = computed(() => {
    return slots.value.reduce((result, slot) => {
      result.set(`${slot.resourceId}|${slot.startsAt}`, slot);
      return result;
    }, new Map());
  });

  const availableCandidatesByDayMinuteKey = computed(() => {
    const result = new Map();

    slots.value.forEach(slot => {
      const startsAt = toDate(slot.startsAt);
      if (Number.isNaN(startsAt.getTime())) return;

      const dateKey = formatDateKey(startsAt);
      const minute = minuteOfDayFromDate(startsAt);
      const bucketMinute =
        Math.floor(minute / slotStepMin.value) * slotStepMin.value;

      pushMapArray(result, dayMinuteKey(dateKey, bucketMinute), slot);
    });

    return result;
  });

  const buildMonthStats = monthDays => {
    const stats = monthDays.reduce((result, day) => {
      result.set(formatDateKey(day), createMonthStat());
      return result;
    }, new Map());

    appointments.value.forEach(appointment => {
      const key = formatDateKey(appointment.startsAt);
      const stat = stats.get(key);
      if (stat) stat.appointments += 1;
    });

    slots.value.forEach(slot => {
      const key = formatDateKey(slot.startsAt);
      const stat = stats.get(key);
      if (stat) stat.availableSlots += 1;
    });

    timeOffs.value.forEach(timeOff => {
      const key = formatDateKey(timeOff.startsAt);
      const stat = stats.get(key);
      if (stat) stat.timeOff += 1;
    });

    monthDays.forEach(day => {
      const key = formatDateKey(day);
      const stat = stats.get(key);
      if (!stat) return;

      stat.holidays = holidays.value.filter(holiday =>
        dayMatchesHoliday(holiday, day)
      ).length;
    });

    return stats;
  };

  const blockingHolidayForDay = day => {
    return (
      holidays.value.find(holiday => {
        return dayMatchesHoliday(holiday, day) && !holiday.workingDayOverride;
      }) || null
    );
  };

  const isRangeAvailable = ({ resourceId, startsAt, endsAt }) => {
    if (!slots.value.length) {
      return true;
    }

    const startDate = toDate(startsAt);
    const endDate = toDate(endsAt);

    if (
      Number.isNaN(startDate.getTime()) ||
      Number.isNaN(endDate.getTime()) ||
      endDate <= startDate
    ) {
      return false;
    }

    const dateKey = formatDateKey(startDate);
    if (formatDateKey(endDate) !== dateKey) {
      return false;
    }

    const durationMs = endDate.getTime() - startDate.getTime();
    const minute = minuteOfDayFromDate(startDate);
    const bucketMinute =
      Math.floor(minute / slotStepMin.value) * slotStepMin.value;
    const candidates =
      availableCandidatesByDayMinuteKey.value.get(
        dayMinuteKey(dateKey, bucketMinute)
      ) || [];

    return candidates.some(candidate => {
      if (Number(candidate.resourceId) !== Number(resourceId)) {
        return false;
      }

      const candidateStart = toDate(candidate.startsAt);
      const candidateEnd = toDate(candidate.endsAt);

      return (
        candidateStart <= startDate &&
        candidateEnd >= endDate &&
        candidateEnd.getTime() - candidateStart.getTime() >= durationMs
      );
    });
  };

  const findFirstAvailableSlotForDay = ({
    day,
    preferredResourceIds = [],
  } = {}) => {
    const dateKey = formatDateKey(day);
    const preferredIds = preferredResourceIds.map(Number);

    const slotsForDay = slots.value
      .filter(slot => formatDateKey(slot.startsAt) === dateKey)
      .sort(
        (left, right) => new Date(left.startsAt) - new Date(right.startsAt)
      );

    if (!slotsForDay.length) {
      return null;
    }

    if (!preferredIds.length) {
      return slotsForDay[0];
    }

    return (
      slotsForDay.find(slot =>
        preferredIds.includes(Number(slot.resourceId))
      ) || slotsForDay[0]
    );
  };

  return {
    availableCandidatesByDayMinuteKey,
    blockingHolidayForDay,
    buildMonthStats,
    findFirstAvailableSlotForDay,
    isRangeAvailable,
    slotMap,
    slotStepMin,
  };
};
