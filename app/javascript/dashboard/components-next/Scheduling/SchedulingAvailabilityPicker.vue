<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { DEFAULT_WORKSPACE_TIMEZONE } from 'dashboard/routes/dashboard/scheduling/constants';

const props = defineProps({
  date: { type: String, default: '' },
  state: { type: String, default: '' },
  windows: { type: Array, default: () => [] },
  selectedStartsAt: { type: String, default: '' },
  nearestState: { type: String, default: '' },
  nearestDate: { type: String, default: '' },
  emptyDate: { type: String, default: '' },
  searchThrough: { type: String, default: '' },
});
const emit = defineEmits(['update:date', 'select', 'showNearest']);
const { t } = useI18n();
const formatTime = value =>
  new Intl.DateTimeFormat('ru', {
    hour: '2-digit',
    minute: '2-digit',
    timeZone: DEFAULT_WORKSPACE_TIMEZONE,
  }).format(new Date(value));

const sortedWindows = computed(() =>
  [...props.windows].sort(
    (first, second) =>
      Date.parse(first.starts_at) - Date.parse(second.starts_at)
  )
);
const isSelected = window =>
  Date.parse(props.selectedStartsAt) === Date.parse(window.starts_at);

const message = computed(() => {
  const nearestMessage = {
    loading: 'SEARCHING',
    found: 'NEAREST_CONFIRMED',
    none: 'NO_NEARBY_CONFIRMED',
    schedule_not_confirmed: 'NEAREST_NOT_CONFIRMED',
    provider_unavailable: 'NEAREST_UNAVAILABLE',
  }[props.nearestState];
  if (nearestMessage)
    return t(`SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.${nearestMessage}`, {
      date: props.emptyDate,
      nearestDate: props.nearestDate,
      through: props.searchThrough,
    });
  if (props.state === 'loading')
    return t('SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.LOADING');
  if (props.state === 'schedule_not_confirmed')
    return t('SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.NOT_CONFIRMED');
  if (props.state === 'provider_unavailable')
    return t('SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.UNAVAILABLE');
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
        type="date"
        class="scheduling-appointment-drawer-control rounded-md border border-n-weak bg-n-alpha-black2 px-2 py-1 text-sm"
        @input="emit('update:date', $event.target.value)"
      />
    </label>
    <p v-if="message" role="status" class="m-0 text-sm text-n-slate-10">
      {{ message }}
    </p>
    <button
      v-if="nearestState === 'found' && nearestDate"
      type="button"
      class="rounded-md border border-n-brand bg-n-brand/10 px-3 py-2 text-sm font-medium text-n-slate-12 hover:bg-n-brand/20 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-n-brand"
      @click="emit('showNearest')"
    >
      {{
        $t('SCHEDULING.APPOINTMENT_FORM.AVAILABILITY.SHOW_NEAREST', {
          date: nearestDate,
        })
      }}
    </button>
    <div
      v-if="state === 'ok' && sortedWindows.length"
      class="grid grid-cols-[repeat(auto-fit,minmax(4.25rem,1fr))] gap-2"
    >
      <button
        v-for="window in sortedWindows"
        :key="`${window.starts_at}-${window.cabinet_code || ''}`"
        type="button"
        :aria-pressed="isSelected(window)"
        class="flex h-9 w-full items-center justify-center rounded-md border px-2 text-sm font-medium tabular-nums text-n-slate-12 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-n-brand"
        :class="
          isSelected(window)
            ? 'border-n-brand bg-n-brand/10'
            : 'border-n-weak bg-n-solid-1 hover:bg-n-alpha-black2'
        "
        @click="emit('select', window)"
      >
        {{ formatTime(window.starts_at) }}
      </button>
    </div>
  </div>
</template>
