<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingEmptyState from 'dashboard/components-next/Scheduling/SchedulingEmptyState.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SchedulingRecordTable from 'dashboard/components-next/Scheduling/SchedulingRecordTable.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import {
  extractSchedulingError,
  toNumeric,
} from 'dashboard/stores/scheduling/shared';
import { toDateTimeInputValue } from '../helpers';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';

const { t, locale } = useI18n();
const referencesStore = useSchedulingReferencesStore();
const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);

const activeTab = ref('workday_overrides');
const drawerOpen = ref(false);
const drawerType = ref('holiday');

const holidayForm = reactive({
  date: '',
  id: null,
  recurringYearly: false,
  title: '',
  workingDayOverride: false,
});

const overrideForm = reactive({
  breakEndMinute: '',
  breakStartMinute: '',
  breakTitle: '',
  date: '',
  endMinute: '',
  id: null,
  resourceId: '',
  startMinute: '',
});

const timeOffForm = reactive({
  endsAt: '',
  id: null,
  kind: 'vacation',
  notes: '',
  resourceId: '',
  startsAt: '',
  title: '',
});

const tabOptions = computed(() => [
  {
    label: t('SCHEDULING.EXCEPTIONS.OVERRIDES_TAB'),
    value: 'workday_overrides',
  },
  { label: t('SCHEDULING.EXCEPTIONS.TIME_OFF_TAB'), value: 'time_offs' },
  { label: t('SCHEDULING.EXCEPTIONS.HOLIDAYS_TAB'), value: 'holidays' },
]);

const activeTabIndex = computed(() =>
  Math.max(
    tabOptions.value.findIndex(option => option.value === activeTab.value),
    0
  )
);

const resourceOptions = computed(() =>
  referencesStore.resources.map(resource => ({
    label: resource.name,
    value: resource.id,
  }))
);

const addActionLabel = computed(() => {
  if (activeTab.value === 'holidays') {
    return t('SCHEDULING.EXCEPTIONS.ADD_HOLIDAY');
  }

  if (activeTab.value === 'workday_overrides') {
    return t('SCHEDULING.EXCEPTIONS.ADD_OVERRIDE');
  }

  return t('SCHEDULING.EXCEPTIONS.ADD_TIME_OFF');
});

const timeOffKindOptions = computed(() => [
  { label: t('SCHEDULING.TIME_OFF.KINDS.VACATION'), value: 'vacation' },
  { label: t('SCHEDULING.TIME_OFF.KINDS.DAY_OFF'), value: 'day_off' },
  { label: t('SCHEDULING.TIME_OFF.KINDS.SICK_LEAVE'), value: 'sick_leave' },
  { label: t('SCHEDULING.TIME_OFF.KINDS.OTHER'), value: 'other' },
]);

const timeOffKindLabel = kind => {
  const labels = {
    day_off: t('SCHEDULING.TIME_OFF.KINDS.DAY_OFF'),
    other: t('SCHEDULING.TIME_OFF.KINDS.OTHER'),
    sick_leave: t('SCHEDULING.TIME_OFF.KINDS.SICK_LEAVE'),
    vacation: t('SCHEDULING.TIME_OFF.KINDS.VACATION'),
  };

  return labels[kind] || labels.other;
};

const currentRows = computed(() => {
  if (activeTab.value === 'holidays') return referencesStore.holidays;
  if (activeTab.value === 'workday_overrides')
    return referencesStore.workdayOverrides;
  return referencesStore.timeOffs;
});

const currentColumns = computed(() => {
  if (activeTab.value === 'holidays') {
    return [
      { key: 'date', label: t('SCHEDULING.GENERAL.DATE'), width: '128px' },
      { key: 'title', label: t('SCHEDULING.GENERAL.TITLE'), width: '1.15fr' },
      {
        key: 'recurring',
        label: t('SCHEDULING.EXCEPTIONS.RECURRING_TABLE'),
        width: '92px',
      },
      {
        key: 'workingDayOverride',
        label: t('SCHEDULING.EXCEPTIONS.WORKING_DAY_OVERRIDE_TABLE'),
        width: '100px',
      },
      { key: 'actions', label: '', width: '84px', align: 'end' },
    ];
  }

  if (activeTab.value === 'workday_overrides') {
    return [
      { key: 'date', label: t('SCHEDULING.GENERAL.DATE'), width: '128px' },
      {
        key: 'resource',
        label: t('SCHEDULING.GENERAL.RESOURCE'),
        width: '1fr',
      },
      { key: 'hours', label: t('SCHEDULING.EXCEPTIONS.HOURS'), width: '124px' },
      { key: 'break', label: t('SCHEDULING.EXCEPTIONS.BREAK'), width: '1.1fr' },
      { key: 'actions', label: '', width: '84px', align: 'end' },
    ];
  }

  return [
    { key: 'resource', label: t('SCHEDULING.GENERAL.RESOURCE'), width: '1fr' },
    { key: 'kind', label: t('SCHEDULING.GENERAL.TYPE'), width: '132px' },
    { key: 'period', label: t('SCHEDULING.GENERAL.DATE'), width: '1.2fr' },
    { key: 'actions', label: '', width: '84px', align: 'end' },
  ];
});

const formatDate = value => {
  if (!value) return '—';

  return new Intl.DateTimeFormat(localeCode.value, {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  }).format(new Date(value));
};

const formatDateTime = value => {
  if (!value) return '—';

  return new Intl.DateTimeFormat(localeCode.value, {
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    month: 'short',
    year: 'numeric',
  }).format(new Date(value));
};

const minuteToTime = minute => {
  if (minute === null || minute === undefined || minute === '') return '—';
  const hours = `${Math.floor(minute / 60)}`.padStart(2, '0');
  const minutes = `${minute % 60}`.padStart(2, '0');
  return `${hours}:${minutes}`;
};

const formatMinuteRange = (startMinute, endMinute) => {
  if (startMinute === null || endMinute === null) {
    return '—';
  }

  return `${minuteToTime(startMinute)} - ${minuteToTime(endMinute)}`;
};

const formatBreakLabel = row => {
  if (row.breakStartMinute === null || row.breakEndMinute === null) {
    return '—';
  }

  const baseLabel = formatMinuteRange(row.breakStartMinute, row.breakEndMinute);
  return row.breakTitle ? `${baseLabel} · ${row.breakTitle}` : baseLabel;
};

const timeToMinute = value => {
  if (!value) return null;
  const [hours = '0', minutes = '0'] = value.split(':');
  return Number(hours) * 60 + Number(minutes);
};

const resourceName = resourceId => {
  return (
    referencesStore.resources.find(resource => resource.id === resourceId)
      ?.name || '—'
  );
};

const resetForms = () => {
  Object.assign(holidayForm, {
    date: '',
    id: null,
    recurringYearly: false,
    title: '',
    workingDayOverride: false,
  });
  Object.assign(overrideForm, {
    breakEndMinute: '',
    breakStartMinute: '',
    breakTitle: '',
    date: '',
    endMinute: '',
    id: null,
    resourceId: '',
    startMinute: '',
  });
  Object.assign(timeOffForm, {
    endsAt: '',
    id: null,
    kind: 'vacation',
    notes: '',
    resourceId: '',
    startsAt: '',
    title: '',
  });
};

const openDrawerForTab = type => {
  drawerType.value = type;
  resetForms();
  drawerOpen.value = true;
};

const editHoliday = holiday => {
  drawerType.value = 'holiday';
  drawerOpen.value = true;
  Object.assign(holidayForm, {
    date: holiday.date,
    id: holiday.id,
    recurringYearly: holiday.recurringYearly,
    title: holiday.title,
    workingDayOverride: holiday.workingDayOverride,
  });
};

const editOverride = item => {
  drawerType.value = 'override';
  drawerOpen.value = true;
  Object.assign(overrideForm, {
    breakEndMinute:
      item.breakEndMinute !== null ? minuteToTime(item.breakEndMinute) : '',
    breakStartMinute:
      item.breakStartMinute !== null ? minuteToTime(item.breakStartMinute) : '',
    breakTitle: item.breakTitle || '',
    date: item.date,
    endMinute: minuteToTime(item.endMinute),
    id: item.id,
    resourceId: item.resourceId,
    startMinute: minuteToTime(item.startMinute),
  });
};

const editTimeOff = item => {
  drawerType.value = 'time_off';
  drawerOpen.value = true;
  Object.assign(timeOffForm, {
    endsAt: toDateTimeInputValue(item.endsAt),
    id: item.id,
    kind: item.kind || 'vacation',
    notes: item.notes || '',
    resourceId: item.resourceId || '',
    startsAt: toDateTimeInputValue(item.startsAt),
    title: item.title || '',
  });
};

const closeDrawer = () => {
  drawerOpen.value = false;
  resetForms();
};

const saveCurrentForm = async () => {
  try {
    if (drawerType.value === 'holiday') {
      await referencesStore.saveHoliday({
        date: holidayForm.date,
        id: holidayForm.id,
        recurring_yearly: holidayForm.recurringYearly,
        title: holidayForm.title,
        working_day_override: holidayForm.workingDayOverride,
      });
    } else if (drawerType.value === 'override') {
      await referencesStore.saveWorkdayOverride({
        break_end_minute: timeToMinute(overrideForm.breakEndMinute),
        break_start_minute: timeToMinute(overrideForm.breakStartMinute),
        break_title: overrideForm.breakTitle,
        date: overrideForm.date,
        end_minute: timeToMinute(overrideForm.endMinute),
        id: overrideForm.id,
        resource_id: toNumeric(overrideForm.resourceId),
        start_minute: timeToMinute(overrideForm.startMinute),
      });
    } else {
      await referencesStore.saveTimeOff({
        ends_at: timeOffForm.endsAt
          ? new Date(timeOffForm.endsAt).toISOString()
          : '',
        id: timeOffForm.id,
        kind: timeOffForm.kind,
        notes: timeOffForm.notes,
        resource_id: toNumeric(timeOffForm.resourceId),
        starts_at: timeOffForm.startsAt
          ? new Date(timeOffForm.startsAt).toISOString()
          : '',
        title: timeOffForm.title,
      });
    }

    closeDrawer();
    useAlert(t('SCHEDULING.EXCEPTIONS.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(extractSchedulingError(error).message);
  }
};

const deleteCurrentRow = async row => {
  try {
    if (activeTab.value === 'holidays') {
      await referencesStore.deleteHoliday(row.id);
    } else if (activeTab.value === 'workday_overrides') {
      await referencesStore.deleteWorkdayOverride(row.id);
    } else {
      await referencesStore.deleteTimeOff(row.id);
    }
    useAlert(t('SCHEDULING.EXCEPTIONS.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(extractSchedulingError(error).message);
  }
};

const drawerTitle = computed(() => {
  if (drawerType.value === 'holiday') {
    return holidayForm.id
      ? t('SCHEDULING.EXCEPTIONS.EDIT_HOLIDAY')
      : t('SCHEDULING.EXCEPTIONS.ADD_HOLIDAY');
  }

  if (drawerType.value === 'override') {
    return overrideForm.id
      ? t('SCHEDULING.EXCEPTIONS.EDIT_OVERRIDE')
      : t('SCHEDULING.EXCEPTIONS.ADD_OVERRIDE');
  }

  return timeOffForm.id
    ? t('SCHEDULING.EXCEPTIONS.EDIT_TIME_OFF')
    : t('SCHEDULING.EXCEPTIONS.ADD_TIME_OFF');
});

onMounted(async () => {
  await Promise.all([
    referencesStore.loadResources({ include_inactive: true }),
    referencesStore.loadExceptions(),
  ]);
});
</script>

<template>
  <section class="flex flex-col flex-1 min-h-0 overflow-y-auto bg-n-surface-1">
    <SchedulingPageHeader :title="$t('SCHEDULING.NAV.EXCEPTIONS')">
      <template #actions>
        <Button
          size="sm"
          icon="i-lucide-plus"
          :label="addActionLabel"
          @click="
            openDrawerForTab(
              activeTab === 'holidays'
                ? 'holiday'
                : activeTab === 'workday_overrides'
                  ? 'override'
                  : 'time_off'
            )
          "
        />
      </template>
    </SchedulingPageHeader>

    <div class="flex flex-col gap-4 px-5 pb-5 pt-3">
      <div
        v-if="
          referencesStore.ui.isLoadingExceptions ||
          referencesStore.ui.isLoadingResources
        "
        class="flex justify-center py-16"
      >
        <Spinner class="!w-8 !h-8" />
      </div>

      <SchedulingErrorState
        v-else-if="referencesStore.ui.error"
        :title="$t('SCHEDULING.GENERAL.ERROR_TITLE')"
        :description="referencesStore.ui.error.message"
        @retry="
          Promise.all([
            referencesStore.loadResources({ include_inactive: true }),
            referencesStore.loadExceptions(),
          ])
        "
      />

      <div v-else class="flex flex-col gap-5">
        <TabBar
          active-text-class="text-n-slate-12 scale-100"
          :tabs="tabOptions"
          :initial-active-tab="activeTabIndex"
          @tab-changed="activeTab = $event.value"
        />

        <SchedulingEmptyState
          v-if="currentRows.length === 0"
          :title="$t('SCHEDULING.EXCEPTIONS.EMPTY_TITLE')"
          :description="$t('SCHEDULING.EXCEPTIONS.EMPTY_DESCRIPTION')"
        />

        <SchedulingRecordTable
          v-else
          :columns="currentColumns"
          :rows="currentRows"
        >
          <template #cell-date="{ row }">
            {{ formatDate(row.date) }}
          </template>

          <template #cell-recurring="{ row }">
            <div class="flex justify-center">
              <span
                class="size-4"
                :class="
                  row.recurringYearly
                    ? 'i-lucide-check text-n-teal-11'
                    : 'i-lucide-minus text-n-slate-10'
                "
              />
            </div>
          </template>

          <template #cell-workingDayOverride="{ row }">
            <div class="flex justify-center">
              <span
                class="size-4"
                :class="
                  row.workingDayOverride
                    ? 'i-lucide-check text-n-teal-11'
                    : 'i-lucide-minus text-n-slate-10'
                "
              />
            </div>
          </template>

          <template #cell-resource="{ row }">
            <span class="block truncate">
              {{ resourceName(row.resourceId) }}
            </span>
          </template>

          <template #cell-hours="{ row }">
            {{ formatMinuteRange(row.startMinute, row.endMinute) }}
          </template>

          <template #cell-break="{ row }">
            <span class="block truncate">
              {{ formatBreakLabel(row) }}
            </span>
          </template>

          <template #cell-kind="{ row }">
            {{ timeOffKindLabel(row.kind) }}
          </template>

          <template #cell-period="{ row }">
            <div class="min-w-0 leading-5">
              <div class="truncate">
                {{ formatDateTime(row.startsAt) }}
              </div>
              <div class="truncate text-xs text-n-slate-11">
                {{ formatDateTime(row.endsAt) }}
              </div>
            </div>
          </template>

          <template #cell-actions="{ row }">
            <div class="flex items-center justify-end gap-1">
              <Button
                size="sm"
                variant="ghost"
                color="slate"
                icon="i-lucide-pencil"
                :aria-label="$t('SCHEDULING.GENERAL.EDIT')"
                :title="$t('SCHEDULING.GENERAL.EDIT')"
                @click="
                  activeTab === 'holidays'
                    ? editHoliday(row)
                    : activeTab === 'workday_overrides'
                      ? editOverride(row)
                      : editTimeOff(row)
                "
              />
              <Button
                size="sm"
                variant="ghost"
                color="ruby"
                icon="i-lucide-trash-2"
                :aria-label="$t('SCHEDULING.GENERAL.DELETE')"
                :title="$t('SCHEDULING.GENERAL.DELETE')"
                @click="deleteCurrentRow(row)"
              />
            </div>
          </template>
        </SchedulingRecordTable>
      </div>
    </div>

    <SchedulingDrawer
      v-model="drawerOpen"
      width="md"
      :title="drawerTitle"
      :confirm-label="$t('SCHEDULING.GENERAL.SAVE')"
      :is-loading="referencesStore.ui.isSaving"
      @close="closeDrawer"
      @confirm="saveCurrentForm"
    >
      <SchedulingFormFieldGroup
        v-if="drawerType === 'holiday'"
        :title="$t('SCHEDULING.EXCEPTIONS.HOLIDAY_FORM_TITLE')"
        :description="$t('SCHEDULING.EXCEPTIONS.HOLIDAY_FORM_DESCRIPTION')"
      >
        <SchedulingDateTimeField
          v-model="holidayForm.date"
          type="date"
          :label="$t('SCHEDULING.GENERAL.DATE')"
        />
        <Input
          v-model="holidayForm.title"
          :label="$t('SCHEDULING.GENERAL.TITLE')"
        />
        <label class="flex items-center gap-3 text-sm text-n-slate-12">
          <Checkbox v-model="holidayForm.recurringYearly" />
          <span>{{ $t('SCHEDULING.EXCEPTIONS.RECURRING') }}</span>
        </label>
        <label class="flex items-center gap-3 text-sm text-n-slate-12">
          <Checkbox v-model="holidayForm.workingDayOverride" />
          <span>{{ $t('SCHEDULING.EXCEPTIONS.WORKING_DAY_OVERRIDE') }}</span>
        </label>
      </SchedulingFormFieldGroup>

      <SchedulingFormFieldGroup
        v-else-if="drawerType === 'override'"
        :title="$t('SCHEDULING.EXCEPTIONS.OVERRIDE_FORM_TITLE')"
        :description="$t('SCHEDULING.EXCEPTIONS.OVERRIDE_FORM_DESCRIPTION')"
      >
        <SchedulingSelectField
          :model-value="overrideForm.resourceId"
          :options="resourceOptions"
          :placeholder="$t('SCHEDULING.GENERAL.RESOURCE')"
          @update:model-value="overrideForm.resourceId = $event"
        />
        <SchedulingDateTimeField
          v-model="overrideForm.date"
          type="date"
          :label="$t('SCHEDULING.GENERAL.DATE')"
        />
        <div class="grid gap-4 md:grid-cols-2">
          <SchedulingDateTimeField
            v-model="overrideForm.startMinute"
            type="time"
            :label="$t('SCHEDULING.GENERAL.START')"
          />
          <SchedulingDateTimeField
            v-model="overrideForm.endMinute"
            type="time"
            :label="$t('SCHEDULING.GENERAL.END')"
          />
          <SchedulingDateTimeField
            v-model="overrideForm.breakStartMinute"
            type="time"
            :label="$t('SCHEDULING.EXCEPTIONS.BREAK_START')"
          />
          <SchedulingDateTimeField
            v-model="overrideForm.breakEndMinute"
            type="time"
            :label="$t('SCHEDULING.EXCEPTIONS.BREAK_END')"
          />
        </div>
        <Input
          v-model="overrideForm.breakTitle"
          :label="$t('SCHEDULING.EXCEPTIONS.BREAK_TITLE')"
        />
      </SchedulingFormFieldGroup>

      <SchedulingFormFieldGroup
        v-else
        :title="$t('SCHEDULING.EXCEPTIONS.TIME_OFF_FORM_TITLE')"
        :description="$t('SCHEDULING.EXCEPTIONS.TIME_OFF_FORM_DESCRIPTION')"
      >
        <SchedulingSelectField
          :model-value="timeOffForm.resourceId"
          :options="resourceOptions"
          :placeholder="$t('SCHEDULING.GENERAL.RESOURCE')"
          @update:model-value="timeOffForm.resourceId = $event"
        />
        <SchedulingSelectField
          :model-value="timeOffForm.kind"
          :options="timeOffKindOptions"
          :placeholder="$t('SCHEDULING.GENERAL.TYPE')"
          @update:model-value="timeOffForm.kind = $event"
        />
        <Input
          v-model="timeOffForm.title"
          :label="$t('SCHEDULING.GENERAL.TITLE')"
        />
        <div class="grid gap-4 md:grid-cols-2">
          <SchedulingDateTimeField
            v-model="timeOffForm.startsAt"
            type="datetime"
            :label="$t('SCHEDULING.GENERAL.START')"
          />
          <SchedulingDateTimeField
            v-model="timeOffForm.endsAt"
            type="datetime"
            :label="$t('SCHEDULING.GENERAL.END')"
          />
        </div>
        <TextArea
          v-model="timeOffForm.notes"
          auto-height
          :label="$t('SCHEDULING.GENERAL.NOTES')"
        />
      </SchedulingFormFieldGroup>
    </SchedulingDrawer>
  </section>
</template>
