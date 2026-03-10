<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import {
  formatTimeLabel,
  minuteOfDayFromDate,
} from 'dashboard/routes/dashboard/scheduling/helpers';

const props = defineProps({
  appointment: {
    type: Object,
    required: true,
  },
  isDragging: {
    type: Boolean,
    default: false,
  },
  resourceColor: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['click', 'drag-start', 'resize-start']);

const { t } = useI18n();

const statusClass = computed(() => {
  const classMap = {
    cancelled: 'bg-n-ruby-4 text-n-ruby-11',
    completed: 'bg-n-teal-4 text-n-teal-11',
    confirmed: 'bg-n-blue-4 text-n-blue-11',
    no_show: 'bg-n-amber-4 text-n-amber-11',
    scheduled: 'bg-n-slate-4 text-n-slate-11',
  };

  return classMap[props.appointment.status] || classMap.scheduled;
});

const paymentClass = computed(() => {
  const classMap = {
    awaiting_payment: 'text-n-amber-11',
    cancelled: 'text-n-ruby-11',
    paid: 'text-n-teal-11',
    prepaid: 'text-n-blue-11',
  };

  return classMap[props.appointment.paymentStatus] || 'text-n-slate-11';
});

const appointmentStatusLabel = computed(() => {
  const labels = {
    cancelled: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
    completed: t('SCHEDULING.APPOINTMENT_STATUS.completed'),
    confirmed: t('SCHEDULING.APPOINTMENT_STATUS.confirmed'),
    no_show: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
    scheduled: t('SCHEDULING.APPOINTMENT_STATUS.scheduled'),
  };

  return labels[props.appointment.status] || labels.scheduled;
});

const paymentStatusLabel = computed(() => {
  const labels = {
    awaiting_payment: t('SCHEDULING.PAYMENT_STATUS.awaiting_payment'),
    cancelled: t('SCHEDULING.PAYMENT_STATUS.cancelled'),
    paid: t('SCHEDULING.PAYMENT_STATUS.paid'),
    prepaid: t('SCHEDULING.PAYMENT_STATUS.prepaid'),
  };

  return labels[props.appointment.paymentStatus] || labels.awaiting_payment;
});

const timeRange = computed(() => {
  return `${formatTimeLabel(minuteOfDayFromDate(props.appointment.startsAt))} - ${formatTimeLabel(minuteOfDayFromDate(props.appointment.endsAt))}`;
});

const backgroundStyle = computed(() => ({
  background: `linear-gradient(135deg, ${props.resourceColor || '#2563eb'}22 0%, ${props.resourceColor || '#2563eb'}55 100%)`,
  borderColor: props.resourceColor || '#2563eb',
}));
</script>

<template>
  <article
    class="absolute inset-x-1 z-10 flex flex-col gap-1 p-2 overflow-hidden text-xs transition-shadow border rounded-xl shadow-sm cursor-pointer select-none"
    :class="[
      statusClass,
      {
        'opacity-60 shadow-none': appointment.status === 'cancelled',
        'shadow-lg ring-2 ring-n-brand/30': isDragging,
      },
    ]"
    :style="backgroundStyle"
    @click.stop="emit('click', appointment)"
    @pointerdown.stop="emit('drag-start', $event)"
  >
    <div class="flex items-start justify-between gap-2">
      <div class="flex flex-col min-w-0">
        <span class="font-semibold truncate text-n-slate-12">
          {{ appointment.clientName }}
        </span>
        <span class="truncate text-n-slate-11">
          {{
            appointment.serviceNameSnapshot ||
            t('SCHEDULING.CALENDAR.NO_SERVICE')
          }}
        </span>
      </div>
      <span class="text-[11px] font-medium text-n-slate-11">
        {{ timeRange }}
      </span>
    </div>

    <div class="flex items-center justify-between gap-2">
      <span class="truncate" :class="paymentClass">
        {{ paymentStatusLabel }}
      </span>
      <span class="px-2 py-0.5 rounded-full bg-n-alpha-2 text-n-slate-11">
        {{ appointmentStatusLabel }}
      </span>
    </div>

    <button
      type="button"
      class="absolute bottom-0 left-0 right-0 h-2 cursor-row-resize"
      @pointerdown.stop="emit('resize-start', $event)"
    />
  </article>
</template>
