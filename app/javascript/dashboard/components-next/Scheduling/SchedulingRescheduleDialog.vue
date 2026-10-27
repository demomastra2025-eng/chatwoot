<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import SchedulingAvailabilityAPI from 'dashboard/api/scheduling/availability';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import SchedulingSelectField from './SchedulingSelectField.vue';
import {
  addMinutesToDateTimeInputValue,
  toDateTimeInputValue,
} from 'dashboard/routes/dashboard/scheduling/helpers';

const props = defineProps({
  appointment: { type: Object, default: null },
  resources: { type: Array, default: () => [] },
  timezone: { type: String, required: true },
  cabinetCode: { type: String, default: '' },
  resourceChangeBlocked: { type: Boolean, default: false },
});
const emit = defineEmits(['select']);
const { t, locale } = useI18n();
const dialog = ref(null);
const selectedResourceId = ref('');
const firstDate = ref('');
const selectedDate = ref('');
const selectedWindow = ref(null);
const windows = ref([]);
const state = ref('');
const loading = ref(false);
let requestId = 0;

const dateAfter = (date, days) => {
  const value = new Date(`${date}T12:00:00Z`);
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
};
const currentStart = computed(() =>
  toDateTimeInputValue(props.appointment?.startsAt, props.timezone)
);
const currentEnd = computed(() =>
  toDateTimeInputValue(props.appointment?.endsAt, props.timezone)
);
const duration = computed(() => Number(props.appointment?.durationMin) || 30);
const days = computed(() =>
  firstDate.value
    ? Array.from({ length: 7 }, (_, index) => dateAfter(firstDate.value, index))
    : []
);
const displayDate = (date, options) =>
  new Intl.DateTimeFormat(locale.value, options).format(
    new Date(`${date}T12:00:00Z`)
  );
const displayTime = startsAt =>
  toDateTimeInputValue(startsAt, props.timezone).slice(11, 16);
const selectedStart = computed(() =>
  selectedWindow.value
    ? toDateTimeInputValue(selectedWindow.value.starts_at, props.timezone)
    : ''
);
const dateChanged = computed(
  () => selectedDate.value !== currentStart.value.slice(0, 10)
);

const open = () => {
  if (!props.appointment) return;
  const today = toDateTimeInputValue(
    new Date().toISOString(),
    props.timezone
  ).slice(0, 10);
  firstDate.value =
    currentStart.value.slice(0, 10) > today
      ? currentStart.value.slice(0, 10)
      : today;
  selectedDate.value = firstDate.value;
  selectedResourceId.value = props.appointment.resourceId;
  selectedWindow.value = null;
  dialog.value?.open();
};
const close = () => dialog.value?.close();
defineExpose({ open, close });

watch([selectedDate, selectedResourceId], async ([date, resourceId]) => {
  requestId += 1;
  const currentRequest = requestId;
  selectedWindow.value = null;
  windows.value = [];
  state.value = '';
  if (!date || !resourceId) return;
  loading.value = true;
  try {
    const { data } = await SchedulingAvailabilityAPI.show({
      date,
      duration_min: duration.value,
      resource_id: resourceId,
      ...(props.appointment?.serviceId
        ? { service_id: props.appointment.serviceId }
        : {}),
      ...(props.cabinetCode ? { cabinet_code: props.cabinetCode } : {}),
    });
    if (currentRequest !== requestId) return;
    state.value = data.payload?.state || '';
    windows.value = (data.payload?.windows || []).filter(window => {
      const start = Date.parse(window.starts_at);
      const end = Date.parse(window.ends_at);
      return (
        Number.isFinite(start) &&
        Number.isFinite(end) &&
        end - start >= duration.value * 60000 &&
        (!props.cabinetCode ||
          String(window.cabinet_code) === String(props.cabinetCode))
      );
    });
  } catch {
    if (currentRequest === requestId) state.value = 'provider_unavailable';
  } finally {
    if (currentRequest === requestId) loading.value = false;
  }
});

const confirm = () => {
  if (!selectedStart.value) return;
  emit('select', {
    resourceId: Number(selectedResourceId.value),
    startsAt: selectedStart.value,
    endsAt: addMinutesToDateTimeInputValue(
      selectedStart.value,
      duration.value,
      props.timezone
    ),
  });
  close();
};
</script>

<template>
  <Dialog
    ref="dialog"
    width="xl"
    :title="t('SCHEDULING.RESCHEDULE.TITLE')"
    :show-confirm-button="false"
  >
    <div class="grid gap-4 text-sm text-n-slate-12">
      <p class="m-0 text-n-slate-11">
        {{ t('SCHEDULING.RESCHEDULE.CURRENT') }}:
        {{ currentStart.replace('T', ' ') }}–{{ currentEnd.slice(11, 16) }} ·
        {{ appointment?.resourceName }}
      </p>
      <SchedulingSelectField
        v-model="selectedResourceId"
        :label="t('SCHEDULING.RESCHEDULE.DOCTOR')"
        :options="
          resources
            .filter(
              resource =>
                !resourceChangeBlocked ||
                Number(resource.id) === Number(appointment?.resourceId)
            )
            .map(resource => ({
              value: resource.id,
              label: resource.name,
            }))
        "
      />
      <p v-if="resourceChangeBlocked" class="m-0 text-xs text-n-amber-11">
        {{ t('SCHEDULING.MEDELEMENT.RESOURCE_CHANGE_UNSUPPORTED') }}
      </p>
      <div class="flex items-center gap-1">
        <Button
          icon="i-lucide-chevron-left"
          variant="ghost"
          :aria-label="t('SCHEDULING.RESCHEDULE.PREVIOUS')"
          @click="
            firstDate = dateAfter(firstDate, -7);
            selectedDate = firstDate;
          "
        />
        <div class="grid min-w-0 flex-1 grid-cols-7 gap-1">
          <button
            v-for="day in days"
            :key="day"
            type="button"
            class="rounded-lg border border-n-weak p-1 text-xs"
            :class="
              day === selectedDate
                ? 'bg-n-brand text-white'
                : 'bg-n-alpha-1 text-n-slate-12'
            "
            @click="selectedDate = day"
          >
            {{ displayDate(day, { weekday: 'short' }) }}<br /><strong>{{
              day.slice(8)
            }}</strong>
          </button>
        </div>
        <Button
          icon="i-lucide-chevron-right"
          variant="ghost"
          :aria-label="t('SCHEDULING.RESCHEDULE.NEXT')"
          @click="
            firstDate = dateAfter(firstDate, 7);
            selectedDate = firstDate;
          "
        />
      </div>
      <p v-if="loading" class="m-0 text-n-slate-11">
        {{ t('SCHEDULING.RESCHEDULE.LOADING') }}
      </p>
      <p v-else-if="!windows.length" class="m-0 text-n-slate-11">
        {{ t('SCHEDULING.RESCHEDULE.NO_SLOTS') }}
      </p>
      <div v-else class="grid grid-cols-4 gap-2 sm:grid-cols-5">
        <button
          v-for="window in windows"
          :key="window.starts_at"
          type="button"
          class="rounded-lg border px-2 py-2 text-sm"
          :class="
            selectedWindow === window
              ? 'border-n-brand bg-n-brand/10 text-n-brand'
              : 'border-n-weak bg-n-alpha-1 text-n-slate-12'
          "
          @click="selectedWindow = window"
        >
          {{ displayTime(window.starts_at) }}
        </button>
      </div>
      <p v-if="state === 'schedule_not_confirmed'" class="m-0 text-n-amber-11">
        {{ t('SCHEDULING.RESCHEDULE.SCHEDULE_NOT_CONFIRMED') }}
      </p>
      <p class="rounded-lg bg-n-alpha-1 p-3 text-xs text-n-slate-11">
        {{ t('SCHEDULING.RESCHEDULE.NOTICE') }}
        <span v-if="dateChanged">{{
          t('SCHEDULING.RESCHEDULE.CONFIRMATION_RESET')
        }}</span>
      </p>
      <div class="flex justify-end gap-2">
        <Button
          variant="faded"
          :label="t('SCHEDULING.GENERAL.CANCEL')"
          @click="close"
        />
        <Button
          :disabled="!selectedWindow || loading || state !== 'ok'"
          :label="
            selectedStart
              ? t('SCHEDULING.RESCHEDULE.CONFIRM_AT', {
                  date: displayDate(selectedDate, {
                    weekday: 'short',
                    day: 'numeric',
                    month: 'numeric',
                  }),
                  time: selectedStart.slice(11, 16),
                })
              : t('SCHEDULING.RESCHEDULE.TITLE')
          "
          @click="confirm"
        />
      </div>
    </div>
  </Dialog>
</template>
