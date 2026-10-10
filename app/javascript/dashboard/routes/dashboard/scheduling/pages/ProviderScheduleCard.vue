<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  schedule: { type: Object, required: true },
});

const { t } = useI18n();
const isExpanded = ref(false);

const checkedMinutesAgo = computed(() => {
  if (!props.schedule.checkedAt) return null;
  return Math.max(
    0,
    Math.floor((Date.now() - Date.parse(props.schedule.checkedAt)) / 60000)
  );
});

const formattedDays = computed(() =>
  (props.schedule.days || []).map(day => ({
    ...day,
    label: new Intl.DateTimeFormat('ru-RU', {
      weekday: 'short',
      day: 'numeric',
      month: 'short',
      timeZone: 'UTC',
    }).format(new Date(`${day.date}T12:00:00Z`)),
    hours: (day.windows || [])
      .map(window => `${window.start}–${window.end}`)
      .join(', '),
  }))
);

const nextWorkingDay = computed(() =>
  formattedDays.value.find(day => day.status === 'confirmed' && day.hours)
);
</script>

<template>
  <section
    class="rounded-xl bg-n-alpha-black2 px-3 py-2 text-xs text-n-slate-11"
  >
    <h4 class="mb-1 text-xs font-semibold text-n-slate-12">
      {{ t('SCHEDULING.RESOURCES.PROVIDER_SCHEDULE_TITLE') }}
    </h4>
    <p v-if="checkedMinutesAgo === null" class="mb-0">
      {{ t('SCHEDULING.RESOURCES.PROVIDER_NOT_LOADED') }}
    </p>
    <template v-else>
      <p class="mb-1">
        {{
          t('SCHEDULING.RESOURCES.PROVIDER_UPDATED', {
            count: checkedMinutesAgo,
          })
        }}
      </p>
      <p
        v-if="!isExpanded && nextWorkingDay"
        class="mb-0 flex justify-between gap-2"
      >
        <span>{{ nextWorkingDay.label }}</span>
        <span>{{ nextWorkingDay.hours }}</span>
      </p>
      <template v-if="isExpanded">
        <p
          v-for="day in formattedDays"
          :key="day.date"
          data-testid="provider-schedule-day"
          class="mb-0 flex justify-between gap-2"
        >
          <span>{{ day.label }}</span>
          <span v-if="day.status === 'confirmed'">{{ day.hours }}</span>
          <span v-else-if="day.status === 'empty_confirmed'">
            {{ t('SCHEDULING.RESOURCES.PROVIDER_DAY_OFF') }}
          </span>
          <span v-else>
            {{ t('SCHEDULING.RESOURCES.PROVIDER_UNVERIFIED') }}
          </span>
        </p>
      </template>
      <Button
        v-if="formattedDays.length"
        type="button"
        size="xs"
        variant="link"
        color="slate"
        class="mt-1"
        :aria-expanded="isExpanded"
        :label="
          isExpanded
            ? t('SCHEDULING.RESOURCES.PROVIDER_HIDE_SCHEDULE')
            : t('SCHEDULING.RESOURCES.PROVIDER_SHOW_SCHEDULE')
        "
        @click="isExpanded = !isExpanded"
      />
    </template>
  </section>
</template>
