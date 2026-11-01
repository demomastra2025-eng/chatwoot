<script setup>
import AvailabilityText from './AvailabilityText.vue';

// Fixed visitor-local dates keep the examples stable across timezones.
const baseTime = new Date(2024, 6, 15, 10);

const defaultProps = {
  time: baseTime,
  workingHours: Array.from({ length: 14 }, (_, offset) => {
    const opening = new Date(2024, 6, 15 + offset, 9);
    const closing = new Date(2024, 6, 15 + offset, 17);
    return { starts_at: opening.toISOString(), ends_at: closing.toISOString() };
  }).filter(slot => new Date(slot.starts_at).getDay() !== 6),
  workingHoursEnabled: true,
  replyTime: 'in_a_few_minutes',
  isOnline: true,
  isInWorkingHours: true,
};

const createVariant = (
  title,
  propsOverride = {},
  isOnlineOverride = null,
  isInWorkingHoursOverride = null
) => {
  const props = { ...defaultProps, ...propsOverride };
  if (isOnlineOverride !== null) props.isOnline = isOnlineOverride;
  if (isInWorkingHoursOverride !== null)
    props.isInWorkingHours = isInWorkingHoursOverride;

  // Adjust time for specific scenarios
  if (title.includes('Back Tomorrow')) {
    // Set time to just after closing on Monday to trigger 'Back Tomorrow' (Tuesday)
    props.time = new Date(2024, 6, 15, 17, 1);
    props.isInWorkingHours = false;
    props.isOnline = false;
  }
  if (title.includes('Back Multiple Days Away')) {
    // Set time to Friday evening to trigger 'Back on Sunday' (as Saturday is closed)
    props.time = new Date(2024, 6, 19, 18);
    props.isInWorkingHours = false;
    props.isOnline = false;
  }
  if (title.includes('Back Same Day - In Minutes')) {
    // Monday 16:50, next slot is 17:00 (in 10 minutes)
    // To make this specific, let's assume the next slot is within the hour
    // For this, we need to be outside working hours but a slot is available soon.
    // Let's say current time is 8:50 AM, office opens at 9:00 AM.
    props.time = new Date(2024, 6, 15, 8, 50);
    props.isInWorkingHours = false;
    props.isOnline = false;
  }
  if (title.includes('Back Same Day - In Hours')) {
    // Monday 07:30 AM, office opens at 9:00 AM (in 1.5 hours, rounds to 2 hours)
    props.time = new Date(2024, 6, 15, 7, 30);
    props.isInWorkingHours = false;
    props.isOnline = false;
  }
  if (title.includes('in 1 hour')) {
    // Monday 08:00 AM, office opens at 9:00 AM (exactly in 1 hour)
    // At exactly 1 hour difference, remainingMinutes = 0
    props.time = new Date(2024, 6, 15, 8);
    props.isInWorkingHours = false;
    props.isOnline = false;
  }
  if (title.includes('Back Same Day - At Time')) {
    // Monday 05:00 AM, office opens at 9:00 AM (at 9:00 AM)
    props.time = new Date(2024, 6, 15, 5);
    props.isInWorkingHours = false;
    props.isOnline = false;
  }

  return {
    title,
    props,
  };
};

const variants = [
  createVariant(
    'Working Hours Disabled - Online',
    { workingHoursEnabled: false },
    true,
    true
  ),
  createVariant(
    'Working Hours Disabled - Offline',
    { workingHoursEnabled: false },
    false,
    false
  ),
  createVariant(
    'All Day Closed - Offline',
    {
      workingHours: [],
    },
    false,
    false
  ),
  createVariant('Online and In Working Hours', {}, true, true),
  createVariant(
    'No Next Slot Available (e.g., all future slots closed or empty workingHours)',
    { workingHours: [] }, // No working hours defined
    false,
    false
  ),
  createVariant(
    'Back Tomorrow',
    {},
    false,
    false // Time will be adjusted by createVariant
  ),
  createVariant('Back Multiple Days Away (e.g., on Sunday)', {}, false, false),
  createVariant(
    'Back Same Day - In Minutes (e.g., in 10 minutes)',
    {},
    false,
    false
  ),
  createVariant(
    'Back Same Day - In Hours (e.g., in 2 hours)',
    {},
    false,
    false
  ),
  createVariant(
    'Back Same Day - Exactly an Hour (e.g., in 1 hour)',
    {},
    false,
    false
  ),
  createVariant(
    'Back Same Day - At Time (e.g., at 09:00 AM)',
    {},
    false,
    false
  ),
];
</script>

<template>
  <Story
    title="Widget/Components/Availability/AvailabilityText"
    :layout="{ type: 'grid', width: 300 }"
  >
    <Variant v-for="(variant, i) in variants" :key="i" :title="variant.title">
      <AvailabilityText
        :time="variant.props.time"
        :working-hours="variant.props.workingHours"
        :working-hours-enabled="variant.props.workingHoursEnabled"
        :reply-time="variant.props.replyTime"
        :is-online="variant.props.isOnline"
        :is-in-working-hours="variant.props.isInWorkingHours"
        class="text-n-slate-11"
      />
    </Variant>
  </Story>
</template>
