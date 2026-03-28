<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import camelcaseKeys from 'camelcase-keys';
import { useI18n } from 'vue-i18n';

import AgentsAPI from 'dashboard/api/agents';
import { useAlert } from 'dashboard/composables';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingColorPicker from 'dashboard/components-next/Scheduling/SchedulingColorPicker.vue';
import SchedulingDurationInput from 'dashboard/components-next/Scheduling/SchedulingDurationInput.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingEmptyState from 'dashboard/components-next/Scheduling/SchedulingEmptyState.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingMoneyInput from 'dashboard/components-next/Scheduling/SchedulingMoneyInput.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SchedulingPercentInput from 'dashboard/components-next/Scheduling/SchedulingPercentInput.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import {
  COMPENSATION_TYPE_VALUES,
  RESOURCE_COLORS,
  WEEKDAY_VALUES,
} from '../constants';
import {
  formatSchedulingErrorMessage,
  toNumeric,
} from 'dashboard/stores/scheduling/shared';
import {
  getUnavailableResourceColors,
  pickResourceColor,
} from '../resourceColors';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';

const { t } = useI18n();

const referencesStore = useSchedulingReferencesStore();

const resourceDrawerOpen = ref(false);
const scheduleDrawerOpen = ref(false);
const scheduleTab = ref('work');
const activeResource = ref(null);
const accountUsers = ref([]);
const resourceDeleteDialogRef = ref(null);
const resourcePendingDelete = ref(null);

const resourceForm = reactive({
  active: true,
  color: RESOURCE_COLORS[0],
  compensationPercent: 0,
  compensationType: 'percent',
  compensationValue: 40,
  description: '',
  id: null,
  name: '',
  photoUrl: '',
  slotDurationMin: 30,
  specialty: '',
  timezone: 'Asia/Almaty',
  userId: '',
});

const scheduleForm = reactive({
  breakRules: [],
  workRules: [],
});

const tabs = computed(() => [
  { label: t('SCHEDULING.RESOURCES.WORK_RULES'), value: 'work' },
  { label: t('SCHEDULING.RESOURCES.BREAK_RULES'), value: 'break' },
]);

const accountUsersById = computed(() => {
  return accountUsers.value.reduce((result, user) => {
    result[user.id] = user;
    return result;
  }, {});
});

const staffOptions = computed(() =>
  accountUsers.value.map(user => ({
    label: [user.name, user.role].filter(Boolean).join(' · '),
    value: user.id,
  }))
);

const compensationTypeLabels = computed(() => ({
  fixed: t('SCHEDULING.COMPENSATION.fixed'),
  fixed_plus_percent: t('SCHEDULING.COMPENSATION.fixed_plus_percent'),
  percent: t('SCHEDULING.COMPENSATION.percent'),
}));

const weekDayLabels = computed(() => ({
  0: t('SCHEDULING.WEEKDAYS.0'),
  1: t('SCHEDULING.WEEKDAYS.1'),
  2: t('SCHEDULING.WEEKDAYS.2'),
  3: t('SCHEDULING.WEEKDAYS.3'),
  4: t('SCHEDULING.WEEKDAYS.4'),
  5: t('SCHEDULING.WEEKDAYS.5'),
  6: t('SCHEDULING.WEEKDAYS.6'),
}));

const compensationTypeOptions = computed(() =>
  COMPENSATION_TYPE_VALUES.map(value => ({
    label: compensationTypeLabels.value[value] || value,
    value,
  }))
);

const formatErrorMessage = error => formatSchedulingErrorMessage(error, t);

const pageErrorDescription = computed(() =>
  formatErrorMessage(referencesStore.ui.error)
);

const resourceCards = computed(() =>
  referencesStore.resources.filter(
    resource => !resource.customAttributes?.deletedFromScheduling
  )
);

const weekDayLabel = weekday => weekDayLabels.value[weekday] || `${weekday}`;

const defaultResourceColor = () =>
  pickResourceColor(resourceCards.value, RESOURCE_COLORS);

const unavailableStandardColors = computed(
  () =>
    new Set(
      getUnavailableResourceColors(
        resourceCards.value,
        RESOURCE_COLORS,
        resourceForm.id
      )
    )
);

const isStandardColorDisabled = color => {
  const normalizedColor = String(color || '')
    .trim()
    .toUpperCase();

  return (
    unavailableStandardColors.value.has(normalizedColor) &&
    resourceForm.color?.toUpperCase() !== normalizedColor
  );
};

const standardColorAriaLabel = color => {
  const suffix = isStandardColorDisabled(color)
    ? `, ${t('SCHEDULING.RESOURCES.COLOR_UNAVAILABLE')}`
    : '';

  return `${t('SCHEDULING.RESOURCES.COLOR')} ${color}${suffix}`;
};

const standardColorTitle = color => {
  if (!isStandardColorDisabled(color)) {
    return color;
  }

  return `${color} · ${t('SCHEDULING.RESOURCES.COLOR_UNAVAILABLE')}`;
};

const compensationPrimaryLabel = type => {
  if (type === 'percent') return t('SCHEDULING.COMPENSATION.percent_value');

  return t('SCHEDULING.COMPENSATION.fixed_value');
};

const compensationSummary = resource => {
  if (resource.compensationType === 'fixed_plus_percent') {
    return `${resource.compensationValue} ₸ + ${resource.compensationPercent}%`;
  }

  if (resource.compensationType === 'percent') {
    return `${resource.compensationValue}%`;
  }

  return `${resource.compensationValue} ₸`;
};

const timeToMinute = value => {
  if (!value) return null;
  const [hours = '0', minutes = '0'] = value.split(':');
  return Number(hours) * 60 + Number(minutes);
};

const minuteToTime = minute => {
  if (minute === null || minute === undefined || minute === '') return '';
  const hours = `${Math.floor(minute / 60)}`.padStart(2, '0');
  const minutes = `${minute % 60}`.padStart(2, '0');
  return `${hours}:${minutes}`;
};

const resetResourceForm = () => {
  Object.assign(resourceForm, {
    active: true,
    color: defaultResourceColor(),
    compensationPercent: 0,
    compensationType: 'percent',
    compensationValue: 40,
    description: '',
    id: null,
    name: '',
    photoUrl: '',
    slotDurationMin: 30,
    specialty: '',
    timezone: 'Asia/Almaty',
    userId: '',
  });
};

const buildDefaultWorkRules = () =>
  WEEKDAY_VALUES.map(weekday => ({
    active: ![0, 6].includes(weekday),
    endMinute: 18 * 60,
    startMinute: 9 * 60,
    weekday,
  }));

const buildDefaultBreakRules = () =>
  WEEKDAY_VALUES.map(weekday => ({
    active: false,
    endMinute: 14 * 60,
    startMinute: 13 * 60,
    title: '',
    weekday,
  }));

let scheduleRowSequence = 0;

const nextScheduleRowKey = () => {
  const rowKey = `schedule-row-${scheduleRowSequence}`;
  scheduleRowSequence += 1;
  return rowKey;
};

const createScheduleRow = rule => {
  const nextRule = {
    active: false,
    endMinute: 18 * 60,
    startMinute: 9 * 60,
    title: '',
    ...rule,
  };

  return {
    ...nextRule,
    rowKey: nextScheduleRowKey(),
    endMinuteText: minuteToTime(nextRule.endMinute),
    startMinuteText: minuteToTime(nextRule.startMinute),
  };
};

const sortScheduleRows = rows => {
  return [...rows].sort((left, right) => {
    if (left.weekday !== right.weekday) {
      return left.weekday - right.weekday;
    }

    const leftMinute = timeToMinute(
      left.startMinuteText || minuteToTime(left.startMinute)
    );
    const rightMinute = timeToMinute(
      right.startMinuteText || minuteToTime(right.startMinute)
    );

    return (leftMinute ?? 0) - (rightMinute ?? 0);
  });
};

const defaultScheduleRuleForType = (type, weekday) => {
  if (type === 'work') {
    return {
      active: false,
      endMinute: 18 * 60,
      startMinute: 9 * 60,
      weekday,
    };
  }

  return {
    active: false,
    endMinute: 14 * 60,
    startMinute: 13 * 60,
    title: '',
    weekday,
  };
};

const buildScheduleRows = (type, rules) => {
  return WEEKDAY_VALUES.flatMap(weekday => {
    const weekdayRules = sortScheduleRows(
      rules.filter(item => item.weekday === weekday)
    );

    if (!weekdayRules.length) {
      return [createScheduleRow(defaultScheduleRuleForType(type, weekday))];
    }

    return weekdayRules.map(rule => createScheduleRow(rule));
  });
};

const scheduleRulesForType = type => {
  return type === 'work' ? scheduleForm.workRules : scheduleForm.breakRules;
};

const replaceScheduleRules = (type, rows) => {
  if (type === 'work') {
    scheduleForm.workRules = rows;
    return;
  }

  scheduleForm.breakRules = rows;
};

const addScheduleRule = (type, weekday) => {
  const rows = scheduleRulesForType(type);
  const weekdayRows = rows.filter(row => row.weekday === weekday);
  const lastWeekdayRow = weekdayRows[weekdayRows.length - 1];
  const defaultRule = defaultScheduleRuleForType(type, weekday);
  const nextRow = createScheduleRow({
    ...defaultRule,
    active: true,
    endMinute:
      timeToMinute(
        lastWeekdayRow?.endMinuteText || minuteToTime(lastWeekdayRow?.endMinute)
      ) ?? defaultRule.endMinute,
    startMinute:
      timeToMinute(
        lastWeekdayRow?.startMinuteText ||
          minuteToTime(lastWeekdayRow?.startMinute)
      ) ?? defaultRule.startMinute,
    title: lastWeekdayRow?.title ?? defaultRule.title,
  });

  replaceScheduleRules(type, sortScheduleRows([...rows, nextRow]));
};

const removeScheduleRule = (type, rowKey) => {
  const rows = scheduleRulesForType(type);
  const targetRow = rows.find(row => row.rowKey === rowKey);

  if (!targetRow) return;

  const weekdayRows = rows.filter(row => row.weekday === targetRow.weekday);
  if (weekdayRows.length === 1) {
    replaceScheduleRules(
      type,
      rows.map(row =>
        row.rowKey === rowKey
          ? createScheduleRow(defaultScheduleRuleForType(type, row.weekday))
          : row
      )
    );
    return;
  }

  replaceScheduleRules(
    type,
    rows.filter(row => row.rowKey !== rowKey)
  );
};

const linkedUser = resource => {
  return accountUsersById.value[resource.userId] || null;
};

const profilePhoto = resource => {
  return resource.photoUrl || linkedUser(resource)?.thumbnail || '';
};

const roleLabel = resource => linkedUser(resource)?.role || '';

const handleUserSelection = userId => {
  resourceForm.userId = userId;
  const user = accountUsersById.value[userId];
  resourceForm.photoUrl = user?.thumbnail || '';
};

const loadAccountUsers = async () => {
  try {
    const { data } = await AgentsAPI.get();
    accountUsers.value = camelcaseKeys(data || [], { deep: true });
  } catch {
    accountUsers.value = [];
  }
};

const openCreateResource = () => {
  resetResourceForm();
  resourceDrawerOpen.value = true;
};

const openEditResource = resource => {
  Object.assign(resourceForm, {
    active: resource.active,
    color: resource.color || RESOURCE_COLORS[0],
    compensationPercent: resource.compensationPercent || 0,
    compensationType: resource.compensationType || 'percent',
    compensationValue: resource.compensationValue || 0,
    description: resource.description || '',
    id: resource.id,
    name: resource.name,
    photoUrl:
      accountUsersById.value[resource.userId]?.thumbnail ||
      resource.photoUrl ||
      '',
    slotDurationMin: resource.slotDurationMin || 30,
    specialty: resource.specialty || '',
    timezone: resource.timezone || 'Asia/Almaty',
    userId: resource.userId || '',
  });
  resourceDrawerOpen.value = true;
};

const closeResourceDrawer = () => {
  resourceDrawerOpen.value = false;
  resetResourceForm();
};

const saveResource = async () => {
  try {
    await referencesStore.saveResource({
      active: resourceForm.active,
      color: resourceForm.color,
      compensation_percent: toNumeric(resourceForm.compensationPercent),
      compensation_type: resourceForm.compensationType,
      compensation_value: toNumeric(resourceForm.compensationValue),
      description: resourceForm.description,
      id: resourceForm.id,
      name: resourceForm.name,
      photo_url: resourceForm.photoUrl,
      slot_duration_min: toNumeric(resourceForm.slotDurationMin),
      specialty: resourceForm.specialty,
      timezone: resourceForm.timezone,
      user_id: toNumeric(resourceForm.userId),
    });
    closeResourceDrawer();
    useAlert(t('SCHEDULING.RESOURCES.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const toggleResourceActive = async resource => {
  try {
    await referencesStore.saveResource({
      active: !resource.active,
      color: resource.color,
      compensation_percent: resource.compensationPercent,
      compensation_type: resource.compensationType,
      compensation_value: resource.compensationValue,
      description: resource.description,
      id: resource.id,
      name: resource.name,
      photo_url: resource.photoUrl,
      slot_duration_min: resource.slotDurationMin,
      specialty: resource.specialty,
      timezone: resource.timezone,
      user_id: resource.userId,
    });
    useAlert(t('SCHEDULING.RESOURCES.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const openDeleteResourceDialog = resource => {
  resourcePendingDelete.value = resource;
  resourceDeleteDialogRef.value?.open();
};

const closeDeleteResourceDialog = () => {
  resourcePendingDelete.value = null;
};

const deleteResource = async () => {
  if (!resourcePendingDelete.value) return;

  try {
    await referencesStore.deleteResource(resourcePendingDelete.value.id);
    resourceDeleteDialogRef.value?.close();
    useAlert(t('SCHEDULING.RESOURCES.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const openScheduleEditor = async resource => {
  activeResource.value = resource;
  scheduleDrawerOpen.value = true;
  scheduleTab.value = 'work';

  const [workRules, breakRules] = await Promise.all([
    referencesStore.loadWorkRules(resource.id),
    referencesStore.loadBreakRules(resource.id),
  ]);

  scheduleForm.workRules = buildScheduleRows(
    'work',
    workRules.length ? workRules : buildDefaultWorkRules()
  );
  scheduleForm.breakRules = buildScheduleRows(
    'break',
    breakRules.length ? breakRules : buildDefaultBreakRules()
  );
};

const closeScheduleDrawer = () => {
  scheduleDrawerOpen.value = false;
  activeResource.value = null;
  scheduleForm.workRules = [];
  scheduleForm.breakRules = [];
};

const saveSchedule = async () => {
  if (!activeResource.value) return;

  try {
    await Promise.all([
      referencesStore.saveWorkRules(
        activeResource.value.id,
        scheduleForm.workRules.map(rule => ({
          active: rule.active,
          end_minute: timeToMinute(
            rule.endMinuteText || minuteToTime(rule.endMinute)
          ),
          start_minute: timeToMinute(
            rule.startMinuteText || minuteToTime(rule.startMinute)
          ),
          weekday: rule.weekday,
        }))
      ),
      referencesStore.saveBreakRules(
        activeResource.value.id,
        scheduleForm.breakRules.map(rule => ({
          active: rule.active,
          end_minute: timeToMinute(
            rule.endMinuteText || minuteToTime(rule.endMinute)
          ),
          start_minute: timeToMinute(
            rule.startMinuteText || minuteToTime(rule.startMinute)
          ),
          title: rule.title,
          weekday: rule.weekday,
        }))
      ),
    ]);
    closeScheduleDrawer();
    useAlert(t('SCHEDULING.RESOURCES.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

onMounted(async () => {
  await Promise.all([
    referencesStore.loadResources({ include_inactive: true }),
    loadAccountUsers(),
  ]);
});
</script>

<template>
  <section class="flex flex-col flex-1 min-h-0 overflow-y-auto bg-n-surface-1">
    <SchedulingPageHeader :title="$t('SCHEDULING.NAV.RESOURCES')">
      <template #actions>
        <Button
          size="sm"
          icon="i-lucide-plus"
          :label="$t('SCHEDULING.RESOURCES.ADD')"
          @click="openCreateResource"
        />
      </template>
    </SchedulingPageHeader>

    <div class="flex flex-col gap-4 px-5 pb-5 pt-3">
      <div
        v-if="referencesStore.ui.isLoadingResources"
        class="flex justify-center py-16"
      >
        <Spinner class="!w-8 !h-8" />
      </div>

      <SchedulingErrorState
        v-else-if="referencesStore.ui.error"
        :title="$t('SCHEDULING.GENERAL.ERROR_TITLE')"
        :description="pageErrorDescription"
        @retry="
          Promise.all([
            referencesStore.loadResources({ include_inactive: true }),
            loadAccountUsers(),
          ])
        "
      />

      <SchedulingEmptyState
        v-else-if="resourceCards.length === 0"
        :title="$t('SCHEDULING.RESOURCES.EMPTY_TITLE')"
        :description="$t('SCHEDULING.RESOURCES.EMPTY_DESCRIPTION')"
        :action-label="$t('SCHEDULING.RESOURCES.ADD')"
        @action="openCreateResource"
      />

      <div v-else class="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
        <article
          v-for="resource in resourceCards"
          :key="resource.id"
          class="flex min-h-[15rem] flex-col gap-3 rounded-2xl bg-n-solid-2 p-4 outline outline-1 outline-n-container shadow-sm"
        >
          <div class="flex items-start gap-3">
            <div class="flex min-w-0 items-start gap-3">
              <Avatar
                :name="resource.name"
                :src="profilePhoto(resource)"
                :size="52"
                rounded-full
              />
              <div class="min-w-0">
                <h3 class="mb-0 truncate text-sm font-semibold text-n-slate-12">
                  {{ resource.name }}
                </h3>
                <div
                  class="mt-1 flex items-center gap-1.5 text-xs text-n-slate-11"
                >
                  <span
                    class="inline-block size-2.5 shrink-0 rounded-full"
                    :style="{
                      backgroundColor: resource.color || RESOURCE_COLORS[0],
                    }"
                  />
                  <p class="mb-0 truncate">
                    {{
                      resource.specialty ||
                      $t('SCHEDULING.RESOURCES.NO_SPECIALTY')
                    }}
                  </p>
                </div>
              </div>
            </div>
          </div>

          <div class="grid gap-2 text-sm">
            <div
              class="flex items-center justify-between gap-3 rounded-xl bg-n-alpha-black2 px-3 py-2 outline outline-1 outline-transparent"
            >
              <span class="text-xs text-n-slate-10">
                {{ $t('SCHEDULING.RESOURCES.LINKED_USER') }}
              </span>
              <div class="min-w-0 text-right">
                <p class="mb-0 truncate text-sm font-medium text-n-slate-12">
                  {{ linkedUser(resource)?.name || '—' }}
                </p>
                <p
                  v-if="roleLabel(resource)"
                  class="mb-0 truncate text-[11px] text-n-slate-11"
                >
                  {{ roleLabel(resource) }}
                </p>
              </div>
            </div>

            <div
              class="flex items-center justify-between gap-3 rounded-xl bg-n-alpha-black2 px-3 py-2 outline outline-1 outline-transparent"
            >
              <span class="text-xs text-n-slate-10">
                {{ $t('SCHEDULING.RESOURCES.SLOT_DURATION') }}
              </span>
              <span class="text-sm font-medium text-n-slate-12">
                {{ resource.slotDurationMin }}
                {{ $t('SCHEDULING.GENERAL.MINUTES') }}
              </span>
            </div>

            <div
              class="flex items-center justify-between gap-3 rounded-xl bg-n-alpha-black2 px-3 py-2 outline outline-1 outline-transparent"
            >
              <span class="text-xs text-n-slate-10">
                {{ $t('SCHEDULING.RESOURCES.COMPENSATION') }}
              </span>
              <span class="truncate text-sm font-medium text-n-slate-12">
                {{ compensationSummary(resource) }}
              </span>
            </div>
          </div>

          <p
            v-if="resource.description"
            class="mb-0 max-h-10 overflow-hidden text-xs leading-5 text-n-slate-11"
          >
            {{ resource.description }}
          </p>

          <div class="mt-auto flex items-center justify-between gap-3">
            <div class="inline-flex items-center">
              <span
                class="rounded-full border border-solid bg-n-alpha-black2 px-2 py-1 text-[11px] font-medium"
                :class="
                  resource.active
                    ? 'bg-n-teal-3 border-n-teal-4 text-n-teal-11'
                    : 'border-n-strong text-n-slate-10'
                "
              >
                {{
                  resource.active
                    ? $t('SCHEDULING.GENERAL.ACTIVE')
                    : $t('SCHEDULING.GENERAL.INACTIVE')
                }}
              </span>
            </div>

            <div class="flex items-center gap-1">
              <Button
                size="sm"
                variant="ghost"
                color="slate"
                icon="i-lucide-pencil"
                :aria-label="$t('SCHEDULING.GENERAL.EDIT')"
                :title="$t('SCHEDULING.GENERAL.EDIT')"
                @click="openEditResource(resource)"
              />
              <Button
                size="sm"
                variant="ghost"
                color="slate"
                icon="i-lucide-calendar-days"
                :aria-label="$t('SCHEDULING.RESOURCES.EDIT_SCHEDULE')"
                :title="$t('SCHEDULING.RESOURCES.EDIT_SCHEDULE')"
                @click="openScheduleEditor(resource)"
              />
              <Button
                size="sm"
                variant="ghost"
                color="slate"
                icon="i-lucide-power"
                :aria-label="
                  resource.active
                    ? $t('SCHEDULING.GENERAL.DEACTIVATE')
                    : $t('SCHEDULING.GENERAL.ACTIVATE')
                "
                :title="
                  resource.active
                    ? $t('SCHEDULING.GENERAL.DEACTIVATE')
                    : $t('SCHEDULING.GENERAL.ACTIVATE')
                "
                @click="toggleResourceActive(resource)"
              />
              <Button
                size="sm"
                variant="ghost"
                color="ruby"
                icon="i-lucide-trash-2"
                :aria-label="$t('SCHEDULING.GENERAL.DELETE')"
                :title="$t('SCHEDULING.GENERAL.DELETE')"
                @click="openDeleteResourceDialog(resource)"
              />
            </div>
          </div>
        </article>
      </div>
    </div>

    <SchedulingDrawer
      v-model="resourceDrawerOpen"
      width="md"
      :title="
        resourceForm.id
          ? $t('SCHEDULING.RESOURCES.EDIT')
          : $t('SCHEDULING.RESOURCES.ADD')
      "
      :confirm-label="$t('SCHEDULING.GENERAL.SAVE')"
      :is-loading="referencesStore.ui.isSaving"
      :disable-confirm="!resourceForm.name"
      @close="closeResourceDrawer"
      @confirm="saveResource"
    >
      <div class="flex flex-col gap-6">
        <SchedulingFormFieldGroup
          :title="$t('SCHEDULING.RESOURCES.BASIC')"
          :description="$t('SCHEDULING.RESOURCES.BASIC_DESCRIPTION')"
        >
          <template #headerActions>
            <label class="flex items-center gap-2 text-sm text-n-slate-12">
              <Switch v-model="resourceForm.active" />
              <span>{{ $t('SCHEDULING.GENERAL.ACTIVE') }}</span>
            </label>
          </template>

          <div class="grid gap-4 md:grid-cols-2">
            <Input
              v-model="resourceForm.name"
              :label="$t('SCHEDULING.RESOURCES.NAME')"
            />
            <Input
              v-model="resourceForm.specialty"
              :label="$t('SCHEDULING.RESOURCES.SPECIALTY')"
            />
            <SchedulingDurationInput
              v-model="resourceForm.slotDurationMin"
              min="5"
              :label="$t('SCHEDULING.RESOURCES.SLOT_DURATION')"
            />
          </div>

          <div class="grid gap-2">
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('SCHEDULING.RESOURCES.LINKED_USER') }}
            </span>
            <div class="grid gap-4 md:max-w-md">
              <SchedulingSelectField
                :model-value="resourceForm.userId"
                :options="staffOptions"
                :placeholder="$t('SCHEDULING.RESOURCES.LINKED_USER')"
                @update:model-value="handleUserSelection($event)"
              />
            </div>
          </div>

          <div
            class="grid gap-4 md:items-end"
            :class="
              resourceForm.compensationType === 'fixed_plus_percent'
                ? 'md:grid-cols-[minmax(0,1fr)_112px_88px]'
                : resourceForm.compensationType === 'percent'
                  ? 'md:grid-cols-[minmax(0,1fr)_88px]'
                  : 'md:grid-cols-[minmax(0,1fr)_112px]'
            "
          >
            <div class="grid gap-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('SCHEDULING.RESOURCES.COMPENSATION') }}
              </span>
              <SchedulingSelectField
                :model-value="resourceForm.compensationType"
                :options="compensationTypeOptions"
                :placeholder="$t('SCHEDULING.RESOURCES.COMPENSATION')"
                @update:model-value="resourceForm.compensationType = $event"
              />
            </div>
            <SchedulingPercentInput
              v-if="resourceForm.compensationType === 'percent'"
              v-model="resourceForm.compensationValue"
              :label="$t('SCHEDULING.COMPENSATION.percent_value')"
            />
            <SchedulingMoneyInput
              v-else
              v-model="resourceForm.compensationValue"
              min="0"
              :label="compensationPrimaryLabel(resourceForm.compensationType)"
            />
            <SchedulingPercentInput
              v-if="resourceForm.compensationType === 'fixed_plus_percent'"
              v-model="resourceForm.compensationPercent"
              :label="$t('SCHEDULING.COMPENSATION.percent_value')"
            />
          </div>

          <div class="grid gap-3">
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('SCHEDULING.RESOURCES.COLOR') }}
            </span>
            <div class="flex flex-wrap gap-2">
              <button
                v-for="color in RESOURCE_COLORS"
                :key="color"
                type="button"
                class="relative size-8 rounded-full border-2 transition-transform hover:scale-105 disabled:cursor-not-allowed disabled:opacity-100 disabled:hover:scale-100"
                :class="[
                  resourceForm.color?.toUpperCase() === color.toUpperCase()
                    ? 'ring-2 ring-offset-2 ring-offset-n-surface-1 ring-n-slate-8 border-n-slate-9'
                    : 'border-n-container',
                  isStandardColorDisabled(color)
                    ? 'border-n-slate-8 shadow-[inset_0_0_0_1px_rgba(15,23,42,0.08)]'
                    : '',
                ]"
                :style="{ backgroundColor: color }"
                :disabled="isStandardColorDisabled(color)"
                :aria-label="standardColorAriaLabel(color)"
                :title="standardColorTitle(color)"
                @click="resourceForm.color = color"
              >
                <span
                  v-if="isStandardColorDisabled(color)"
                  class="pointer-events-none absolute -bottom-0.5 -right-0.5 flex size-4 items-center justify-center rounded-full bg-n-surface-1 text-n-slate-12 outline outline-1 outline-n-container shadow-sm"
                  aria-hidden="true"
                >
                  <span class="size-2.5 i-lucide-slash" />
                </span>
              </button>
            </div>
            <div class="grid gap-2 md:max-w-xs">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('SCHEDULING.RESOURCES.CUSTOM_COLOR') }}
              </span>
              <SchedulingColorPicker v-model="resourceForm.color" />
            </div>
          </div>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup>
          <TextArea
            v-model="resourceForm.description"
            auto-height
            :label="$t('SCHEDULING.GENERAL.COMMENTS')"
          />
        </SchedulingFormFieldGroup>
      </div>
    </SchedulingDrawer>

    <SchedulingDrawer
      v-model="scheduleDrawerOpen"
      width="xl"
      :title="
        $t('SCHEDULING.RESOURCES.SCHEDULE_TITLE', {
          name: activeResource?.name || '',
        })
      "
      :confirm-label="$t('SCHEDULING.GENERAL.SAVE')"
      :is-loading="referencesStore.ui.isSaving"
      @close="closeScheduleDrawer"
      @confirm="saveSchedule"
    >
      <div class="flex flex-col gap-6">
        <TabBar
          active-text-class="text-n-slate-12 scale-100"
          :tabs="tabs"
          :initial-active-tab="scheduleTab === 'work' ? 0 : 1"
          @tab-changed="scheduleTab = $event.value"
        />

        <div v-if="scheduleTab === 'work'" class="flex flex-col gap-4">
          <div
            v-for="rule in scheduleForm.workRules"
            :key="rule.rowKey"
            class="grid items-center gap-4 rounded-2xl bg-n-surface-1 p-4 outline outline-1 outline-n-container md:grid-cols-[160px_100px_1fr_1fr_88px]"
          >
            <span class="text-sm font-medium text-n-slate-12">
              {{ weekDayLabel(rule.weekday) }}
            </span>
            <label class="flex items-center gap-2 text-sm text-n-slate-11">
              <Switch v-model="rule.active" />
              <span>{{ $t('SCHEDULING.GENERAL.ACTIVE') }}</span>
            </label>
            <SchedulingDateTimeField
              v-model="rule.startMinuteText"
              type="time"
              :label="$t('SCHEDULING.GENERAL.START')"
            />
            <SchedulingDateTimeField
              v-model="rule.endMinuteText"
              type="time"
              :label="$t('SCHEDULING.GENERAL.END')"
            />
            <div class="flex items-center justify-end gap-1">
              <Button
                size="xs"
                variant="ghost"
                color="slate"
                icon="i-lucide-plus"
                :aria-label="$t('SCHEDULING.GENERAL.CREATE')"
                :title="$t('SCHEDULING.GENERAL.CREATE')"
                @click="addScheduleRule('work', rule.weekday)"
              />
              <Button
                size="xs"
                variant="ghost"
                color="ruby"
                icon="i-lucide-trash-2"
                :aria-label="$t('SCHEDULING.GENERAL.DELETE')"
                :title="$t('SCHEDULING.GENERAL.DELETE')"
                @click="removeScheduleRule('work', rule.rowKey)"
              />
            </div>
          </div>
        </div>

        <div v-else class="flex flex-col gap-4">
          <div
            v-for="rule in scheduleForm.breakRules"
            :key="rule.rowKey"
            class="grid items-center gap-4 rounded-2xl bg-n-surface-1 p-4 outline outline-1 outline-n-container md:grid-cols-[160px_100px_1fr_1fr_1.2fr_88px]"
          >
            <span class="text-sm font-medium text-n-slate-12">
              {{ weekDayLabel(rule.weekday) }}
            </span>
            <label class="flex items-center gap-2 text-sm text-n-slate-11">
              <Switch v-model="rule.active" />
              <span>{{ $t('SCHEDULING.GENERAL.ACTIVE') }}</span>
            </label>
            <SchedulingDateTimeField
              v-model="rule.startMinuteText"
              type="time"
              :label="$t('SCHEDULING.GENERAL.START')"
            />
            <SchedulingDateTimeField
              v-model="rule.endMinuteText"
              type="time"
              :label="$t('SCHEDULING.GENERAL.END')"
            />
            <Input
              v-model="rule.title"
              :label="$t('SCHEDULING.RESOURCES.BREAK_TITLE')"
            />
            <div class="flex items-center justify-end gap-1">
              <Button
                size="xs"
                variant="ghost"
                color="slate"
                icon="i-lucide-plus"
                :aria-label="$t('SCHEDULING.GENERAL.CREATE')"
                :title="$t('SCHEDULING.GENERAL.CREATE')"
                @click="addScheduleRule('break', rule.weekday)"
              />
              <Button
                size="xs"
                variant="ghost"
                color="ruby"
                icon="i-lucide-trash-2"
                :aria-label="$t('SCHEDULING.GENERAL.DELETE')"
                :title="$t('SCHEDULING.GENERAL.DELETE')"
                @click="removeScheduleRule('break', rule.rowKey)"
              />
            </div>
          </div>
        </div>
      </div>
    </SchedulingDrawer>

    <Dialog
      ref="resourceDeleteDialogRef"
      width="md"
      type="alert"
      :title="$t('SCHEDULING.RESOURCES.DELETE_TITLE')"
      :description="
        $t('SCHEDULING.RESOURCES.DELETE_DESCRIPTION', {
          name: resourcePendingDelete?.name || '',
        })
      "
      :confirm-button-label="$t('SCHEDULING.RESOURCES.DELETE_CONFIRM')"
      :is-loading="referencesStore.ui.isSaving"
      @close="closeDeleteResourceDialog"
      @confirm="deleteResource"
    />
  </section>
</template>
