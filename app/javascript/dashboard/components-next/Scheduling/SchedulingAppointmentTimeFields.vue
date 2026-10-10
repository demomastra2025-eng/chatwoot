<script setup>
import { watch } from 'vue';
import Input from 'dashboard/components-next/input/Input.vue';
import SchedulingDateTimeField from './SchedulingDateTimeField.vue';
import {
  addMinutesToDateTimeInputValue,
  fromDateTimeInputValue,
} from 'dashboard/routes/dashboard/scheduling/helpers';
import { DEFAULT_WORKSPACE_TIMEZONE } from 'dashboard/routes/dashboard/scheduling/constants';

defineProps({
  idPrefix: { type: String, required: true },
  disabled: { type: Boolean, default: false },
  startsAtMessage: { type: String, default: '' },
  endsAtMessage: { type: String, default: '' },
});
const emit = defineEmits(['change']);
const startsAt = defineModel('startsAt', { type: String, default: '' });
const endsAt = defineModel('endsAt', { type: String, default: '' });
const durationMin = defineModel('durationMin', {
  type: [String, Number],
  default: 30,
});

const validDuration = value =>
  Number.isInteger(Number(value)) && Number(value) >= 5 && Number(value) <= 1440;

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
  <div class="grid gap-3">
    <SchedulingDateTimeField
      :id="`${idPrefix}-starts-at`"
      :model-value="startsAt"
      :label="$t('SCHEDULING.APPOINTMENT_FORM.STARTS_AT')"
      :disabled="disabled"
      :message="startsAtMessage"
      :message-type="startsAtMessage ? 'error' : 'info'"
      editable
      time-picker-variant="field"
      @update:model-value="updateStart"
    />
    <SchedulingDateTimeField
      :id="`${idPrefix}-ends-at`"
      :model-value="endsAt"
      :label="$t('SCHEDULING.APPOINTMENT_FORM.ENDS_AT')"
      :disabled="disabled"
      :message="endsAtMessage"
      :message-type="endsAtMessage ? 'error' : 'info'"
      editable
      time-picker-variant="field"
      @update:model-value="updateEnd"
    />
    <Input
      :id="`${idPrefix}-duration-min`"
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
</template>
