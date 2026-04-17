<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';

import NextButton from 'dashboard/components-next/button/Button.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import { toDateTimeInputValue } from 'dashboard/routes/dashboard/scheduling/helpers';

const emit = defineEmits(['close', 'chooseTime']);

const roundUpToNextFiveMinutes = value => {
  const nextValue = new Date(value);
  nextValue.setSeconds(0, 0);

  const remainder = nextValue.getMinutes() % 5;
  if (remainder !== 0) {
    nextValue.setMinutes(nextValue.getMinutes() + (5 - remainder));
  }

  return nextValue;
};

const buildMinimumSnoozeTime = () => {
  const nextValue = roundUpToNextFiveMinutes(new Date());
  nextValue.setHours(nextValue.getHours() + 1);
  return nextValue;
};

const minimumSnoozeTime = ref(buildMinimumSnoozeTime());
const snoozeTime = ref(toDateTimeInputValue(minimumSnoozeTime.value));
let minimumTimeRefreshInterval = null;

const refreshMinimumSnoozeTime = () => {
  minimumSnoozeTime.value = buildMinimumSnoozeTime();
};

const isSelectionInvalid = computed(() => {
  if (!snoozeTime.value) {
    return true;
  }

  const selectedAt = new Date(snoozeTime.value);
  return (
    Number.isNaN(selectedAt.getTime()) ||
    selectedAt.getTime() < minimumSnoozeTime.value.getTime()
  );
});

const validationMessage = computed(() => {
  return isSelectionInvalid.value
    ? 'CONVERSATION.CUSTOM_SNOOZE.MINIMUM_NOTICE'
    : '';
});

const disabledPastDates = date => {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return date < today;
};

const onClose = () => {
  emit('close');
};

const chooseTime = () => {
  if (isSelectionInvalid.value) {
    return;
  }

  emit('chooseTime', new Date(snoozeTime.value));
};

onMounted(() => {
  minimumTimeRefreshInterval = window.setInterval(
    refreshMinimumSnoozeTime,
    30 * 1000
  );
});

onBeforeUnmount(() => {
  if (minimumTimeRefreshInterval) {
    window.clearInterval(minimumTimeRefreshInterval);
  }
});
</script>

<template>
  <div class="flex w-full max-w-[32rem] min-w-0 flex-col overflow-x-hidden">
    <woot-modal-header :header-title="$t('CONVERSATION.CUSTOM_SNOOZE.TITLE')" />
    <form
      class="modal-content box-border flex w-full max-w-full min-w-0 self-stretch flex-col gap-4 overflow-x-hidden px-5 pb-6 pt-2"
      @submit.prevent="chooseTime"
    >
      <SchedulingDateTimeField
        v-model="snoozeTime"
        type="datetime"
        :label="$t('CONVERSATION.CUSTOM_SNOOZE.TITLE')"
        :disabled-date="disabledPastDates"
        :message="
          validationMessage
            ? $t('CONVERSATION.CUSTOM_SNOOZE.MINIMUM_NOTICE')
            : ''
        "
        :message-type="isSelectionInvalid ? 'error' : 'info'"
      />

      <div class="flex flex-wrap justify-end gap-2 px-0 py-2">
        <NextButton
          faded
          slate
          type="reset"
          :label="$t('CONVERSATION.CUSTOM_SNOOZE.CANCEL')"
          @click.prevent="onClose"
        />
        <NextButton
          type="submit"
          :disabled="isSelectionInvalid"
          :label="$t('CONVERSATION.CUSTOM_SNOOZE.APPLY')"
        />
      </div>
    </form>
  </div>
</template>
