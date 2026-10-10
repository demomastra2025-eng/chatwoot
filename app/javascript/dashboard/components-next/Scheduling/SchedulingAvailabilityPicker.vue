<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { DEFAULT_WORKSPACE_TIMEZONE } from 'dashboard/routes/dashboard/scheduling/constants';

const props = defineProps({
  date: { type: String, default: '' },
  maxDate: { type: String, default: '' },
  state: { type: String, default: '' },
  windows: { type: Array, default: () => [] },
  selectedStartsAt: { type: String, default: '' },
});
const emit = defineEmits(['update:date', 'select']);
const { t } = useI18n();
const todayParts = Object.fromEntries(
  new Intl.DateTimeFormat('en', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    timeZone: DEFAULT_WORKSPACE_TIMEZONE,
  })
    .formatToParts(new Date())
    .map(part => [part.type, part.value])
);
const today = `${todayParts.year}-${todayParts.month}-${todayParts.day}`;

const formatDate = date => {
  if (!date) return '';
  const [year, month, day] = date.split('-');
  return `${day}.${month}.${year}`;
};
const formatTime = value =>
  new Intl.DateTimeFormat('ru', {
    hour: '2-digit',
    minute: '2-digit',
    timeZone: DEFAULT_WORKSPACE_TIMEZONE,
  }).format(new Date(value));

const message = computed(() => {
  if (props.state === 'loading')
    return t('SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.LOADING');
  if (props.state === 'schedule_not_confirmed')
    return t('SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.NOT_CONFIRMED');
  if (props.state === 'provider_unavailable')
    return t('SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.UNAVAILABLE');
  if (props.state === 'beyond_horizon')
    return t('SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.HORIZON', {
      date: formatDate(props.maxDate),
    });
  if (
    props.state === 'closed_day' ||
    (props.state === 'ok' && !props.windows.length)
  ) {
    return t('SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.EMPTY');
  }
  return '';
});
</script>

<template>
  <div class="grid gap-2">
    <label class="scheduling-appointment-drawer-label">
      {{ $t('SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.DATE') }}
      <input
        :value="date"
        :max="maxDate || undefined"
        :min="today"
        type="date"
        class="scheduling-appointment-drawer-control rounded-md border border-n-weak bg-n-alpha-black2 px-2 py-1 text-sm"
        @input="emit('update:date', $event.target.value)"
      />
    </label>
    <p v-if="message" role="status" class="m-0 text-sm text-n-slate-10">
      {{ message }}
    </p>
    <div v-if="state === 'ok' && windows.length" class="flex flex-wrap gap-2">
      <button
        v-for="window in windows"
        :key="`${window.starts_at}-${window.cabinet_code || ''}`"
        type="button"
        :aria-pressed="selectedStartsAt === window.starts_at"
        class="rounded-md border border-n-weak px-2 py-1 text-sm text-n-slate-12"
        :class="
          selectedStartsAt === window.starts_at
            ? 'border-n-brand bg-n-brand/10'
            : ''
        "
        @click="emit('select', window)"
      >
        {{ formatTime(window.starts_at) }}–{{ formatTime(window.ends_at) }}
      </button>
    </div>
  </div>
</template>
