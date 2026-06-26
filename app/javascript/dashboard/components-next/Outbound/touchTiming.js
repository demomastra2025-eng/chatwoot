export const TOUCH_TIMING_STATES = {
  ABSOLUTE: 'absolute',
  AFTER: 'after',
  BEFORE: 'before',
};

export const RELATIVE_TIME_MODES = {
  INHERIT_ANCHOR_TIME: 'inherit_anchor_time',
  FIXED_TIME_OF_DAY: 'fixed_time_of_day',
};

export const DEFAULT_RELATIVE_TIME_OF_DAY = '10:00';
export const FIXED_RELATIVE_TIME_UNIT = 'days';

export const RELATIVE_OFFSET_UNIT_SECONDS = {
  minutes: 60,
  hours: 60 * 60,
  days: 24 * 60 * 60,
};

export const normalizeRelativeOffset = totalSeconds => {
  const numericValue = Number(totalSeconds || 0);
  const safeSeconds = Number.isFinite(numericValue)
    ? Math.abs(numericValue)
    : 0;

  if (safeSeconds <= 0) {
    return {
      direction: TOUCH_TIMING_STATES.AFTER,
      unit: 'minutes',
      value: 1,
    };
  }

  const orderedUnits = ['days', 'hours', 'minutes'];
  const matchedUnit =
    orderedUnits.find(
      unit => safeSeconds % RELATIVE_OFFSET_UNIT_SECONDS[unit] === 0
    ) || 'minutes';

  const unitSeconds = RELATIVE_OFFSET_UNIT_SECONDS[matchedUnit];
  const normalizedValue = unitSeconds
    ? safeSeconds / unitSeconds
    : safeSeconds / 60;

  return {
    direction:
      numericValue < 0 ? TOUCH_TIMING_STATES.BEFORE : TOUCH_TIMING_STATES.AFTER,
    unit: matchedUnit,
    value: Math.max(
      1,
      Number.isFinite(normalizedValue) ? Number(normalizedValue.toFixed(3)) : 1
    ),
  };
};

export const toRelativeOffsetSeconds = ({ direction, unit, value }) => {
  const normalizedUnit = RELATIVE_OFFSET_UNIT_SECONDS[unit] ? unit : 'minutes';
  const normalizedValue = Math.max(1, Number(value || 0));
  const totalSeconds =
    normalizedValue * RELATIVE_OFFSET_UNIT_SECONDS[normalizedUnit];
  const sanitizedTotalSeconds = Number.isFinite(totalSeconds)
    ? totalSeconds
    : 0;

  return direction === TOUCH_TIMING_STATES.BEFORE
    ? -Math.abs(sanitizedTotalSeconds)
    : Math.abs(sanitizedTotalSeconds);
};

export const canUseFixedRelativeTimeForUnit = unit =>
  unit === FIXED_RELATIVE_TIME_UNIT;

export const normalizeRelativeTimeForUnit = ({
  relativeTimeMode,
  relativeTimeOfDay,
  unit,
}) => {
  if (
    !canUseFixedRelativeTimeForUnit(unit) ||
    relativeTimeMode !== RELATIVE_TIME_MODES.FIXED_TIME_OF_DAY
  ) {
    return {
      relativeTimeMode: RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME,
      relativeTimeOfDay: '',
    };
  }

  return {
    relativeTimeMode: RELATIVE_TIME_MODES.FIXED_TIME_OF_DAY,
    relativeTimeOfDay: relativeTimeOfDay || DEFAULT_RELATIVE_TIME_OF_DAY,
  };
};

export const resolveTouchTimingState = ({
  relativeOffsetSeconds,
  timingMode,
}) => {
  if (timingMode === TOUCH_TIMING_STATES.ABSOLUTE) {
    return TOUCH_TIMING_STATES.ABSOLUTE;
  }

  return Number(relativeOffsetSeconds || 0) < 0
    ? TOUCH_TIMING_STATES.BEFORE
    : TOUCH_TIMING_STATES.AFTER;
};
