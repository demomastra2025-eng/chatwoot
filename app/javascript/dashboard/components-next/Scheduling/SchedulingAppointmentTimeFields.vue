<script setup>
import { computed, watch } from 'vue';
import Input from 'dashboard/components-next/input/Input.vue';
import SchedulingDateTimeField from './SchedulingDateTimeField.vue';
import {
  addMinutesToDateTimeInputValue,
  fromDateTimeInputValue,
} from 'dashboard/routes/dashboard/scheduling/helpers';
import { DEFAULT_WORKSPACE_TIMEZONE } from 'dashboard/routes/dashboard/scheduling/constants';

const props = defineProps({
  idPrefix: { type: String, required: true },
  disabled: { type: Boolean, default: false },
  startsAtMessage: { type: String, default: '' },
  endsAtMessage: { type: String, default: '' },
  layout: {
    type: String,
    default: 'stack',
    validator: value => ['stack', 'rows'].includes(value),
  },
});
const emit = defineEmits(['change']);
const startsAt = defineModel('startsAt', { type: String, default: '' });
const endsAt = defineModel('endsAt', { type: String, default: '' });
const durationMin = defineModel('durationMin', {
  type: [String, Number],
  default: 30,
});
const isRowsLayout = computed(() => props.layout === 'rows');

const validDuration = value =>
  Number.isInteger(Number(value)) &&
  Number(value) >= 5 &&
  Number(value) <= 1440;

const synchronizeDuration = () => {
  const from = Date.parse(
    fromDateTimeInputValue(startsAt.value, DEFAULT_WORKSPACE_TIMEZONE) || ''
  );
  const to = Date.parse(
    fromDateTimeInputValue(endsAt.value, DEFAULT_WORKSPACE_TIMEZONE) || ''
  );
  if (Number.isFinite(from) && Number.isFinite(to) && to > from) {
    durationMin.value = (to - from) / 60000;
  }
};

const safeSynchronizeDuration = () => {
  try {
    synchronizeDuration();
  } catch {
    // Invalid draft text remains editable; interval validation prevents saving.
  }
};

const updateStart = value => {
  startsAt.value = value;
  if (value && validDuration(durationMin.value)) {
    endsAt.value = addMinutesToDateTimeInputValue(
      value,
      Number(durationMin.value),
      DEFAULT_WORKSPACE_TIMEZONE
    );
  }
  emit('change', 'start');
};

const updateEnd = value => {
  endsAt.value = value;
  safeSynchronizeDuration();
  emit('change', 'end');
};

const updateDuration = value => {
  durationMin.value = value;
  if (startsAt.value && validDuration(value)) {
    endsAt.value = addMinutesToDateTimeInputValue(
      startsAt.value,
      Number(value),
      DEFAULT_WORKSPACE_TIMEZONE
    );
  }
  emit('change', 'duration');
};

watch([startsAt, endsAt], () => {
  if (validDuration(durationMin.value)) safeSynchronizeDuration();
});
</script>

<template>
  <div
    :class="
      isRowsLayout
        ? 'scheduling-appointment-time-rows grid gap-2'
        : 'grid gap-3'
    "
  >
    <div :class="{ 'scheduling-appointment-time-row': isRowsLayout }">
      <span v-if="isRowsLayout" class="scheduling-appointment-time-label">
        {{ $t('SCHEDULING.APPOINTMENT_FORM.STARTS_AT') }}
      </span>
      <SchedulingDateTimeField
        :id="`${idPrefix}-starts-at`"
        class="scheduling-appointment-time-control"
        :model-value="startsAt"
        :label="$t('SCHEDULING.APPOINTMENT_FORM.STARTS_AT')"
        :disabled="disabled"
        :message="startsAtMessage"
        :message-type="startsAtMessage ? 'error' : 'info'"
        editable
        time-picker-variant="field"
        @update:model-value="updateStart"
      />
    </div>
    <div :class="{ 'scheduling-appointment-time-row': isRowsLayout }">
      <span v-if="isRowsLayout" class="scheduling-appointment-time-label">
        {{ $t('SCHEDULING.APPOINTMENT_FORM.ENDS_AT') }}
      </span>
      <SchedulingDateTimeField
        :id="`${idPrefix}-ends-at`"
        class="scheduling-appointment-time-control"
        :model-value="endsAt"
        :label="$t('SCHEDULING.APPOINTMENT_FORM.ENDS_AT')"
        :disabled="disabled"
        :message="endsAtMessage"
        :message-type="endsAtMessage ? 'error' : 'info'"
        editable
        time-picker-variant="field"
        @update:model-value="updateEnd"
      />
    </div>
    <div :class="{ 'scheduling-appointment-time-row': isRowsLayout }">
      <label
        v-if="isRowsLayout"
        class="scheduling-appointment-time-label"
        :for="`${idPrefix}-duration-min`"
      >
        {{ $t('SCHEDULING.APPOINTMENT_FORM.DURATION_MIN') }}
      </label>
      <Input
        :id="`${idPrefix}-duration-min`"
        class="scheduling-appointment-time-control"
        :model-value="durationMin"
        :label="$t('SCHEDULING.APPOINTMENT_FORM.DURATION_MIN')"
        :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.DURATION_MIN')"
        :disabled="disabled"
        :message="
          validDuration(durationMin)
            ? ''
            : $t('SCHEDULING.APPOINTMENT_FORM.ERRORS.INVALID_DURATION')
        "
        :message-type="validDuration(durationMin) ? 'info' : 'error'"
        type="number"
        inputmode="numeric"
        min="5"
        max="1440"
        step="1"
        size="sm"
        @update:model-value="updateDuration"
      />
    </div>
  </div>
</template>

<style scoped>
.scheduling-appointment-time-row {
  display: grid;
  gap: 0.375rem;
  min-width: 0;
}

.scheduling-appointment-time-label {
  @apply mb-0 min-w-0 text-[13px] font-medium leading-4 text-n-slate-12;
}

.scheduling-appointment-time-control {
  width: 100%;
  min-width: 0;
}

.scheduling-appointment-time-rows
  :deep(.scheduling-appointment-time-control > span.mb-0\.5),
.scheduling-appointment-time-rows
  :deep(.scheduling-appointment-time-control > label) {
  @apply sr-only;
}

@media (min-width: 768px) {
  .scheduling-appointment-time-row {
    align-items: center;
    grid-template-columns: minmax(6.5rem, 1fr) minmax(8rem, 14rem);
  }
}
</style>
