<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import camelcaseKeys from 'camelcase-keys';
import { useI18n } from 'vue-i18n';

import AgentsAPI from 'dashboard/api/agents';
import { useAlert } from 'dashboard/composables';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
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
import SchedulingSectionCard from 'dashboard/components-next/Scheduling/SchedulingSectionCard.vue';
import {
  COMPENSATION_TYPE_VALUES,
  RESOURCE_COLORS,
  WEEKDAY_VALUES,
} from '../constants';
import {
  extractSchedulingError,
  toNumeric,
} from 'dashboard/stores/scheduling/shared';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';

const { t } = useI18n();

const referencesStore = useSchedulingReferencesStore();

const resourceDrawerOpen = ref(false);
const scheduleDrawerOpen = ref(false);
const scheduleTab = ref('work');
const activeResource = ref(null);
const accountUsers = ref([]);

const resourceForm = reactive({
  active: true,
  color: RESOURCE_COLORS[0],
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

const weekDayLabel = weekday => weekDayLabels.value[weekday] || `${weekday}`;

const compensationTypeLabel = type => {
  return compensationTypeLabels.value[type] || type;
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
    color: RESOURCE_COLORS[0],
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

const resourceCards = computed(() => referencesStore.resources);

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

  if (user?.thumbnail && !resourceForm.photoUrl) {
    resourceForm.photoUrl = user.thumbnail;
  }
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
    compensationType: resource.compensationType || 'percent',
    compensationValue: resource.compensationValue || 0,
    description: resource.description || '',
    id: resource.id,
    name: resource.name,
    photoUrl: resource.photoUrl || '',
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
    useAlert(extractSchedulingError(error).message);
  }
};

const toggleResourceActive = async resource => {
  try {
    await referencesStore.saveResource({
      active: !resource.active,
      color: resource.color,
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
    useAlert(extractSchedulingError(error).message);
  }
};

const deleteResource = async resource => {
  try {
    await referencesStore.deleteResource(resource.id);
    useAlert(t('SCHEDULING.RESOURCES.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(extractSchedulingError(error).message);
  }
};

const buildScheduleRows = rules => {
  return WEEKDAY_VALUES.map(weekday => {
    const rule = rules.find(item => item.weekday === weekday);
    const nextRule = rule || {
      active: false,
      endMinute: 18 * 60,
      startMinute: 9 * 60,
      title: '',
      weekday,
    };

    return {
      ...nextRule,
      endMinuteText: minuteToTime(nextRule.endMinute),
      startMinuteText: minuteToTime(nextRule.startMinute),
    };
  });
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
    workRules.length ? workRules : buildDefaultWorkRules()
  );
  scheduleForm.breakRules = buildScheduleRows(
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
    useAlert(extractSchedulingError(error).message);
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
    <SchedulingPageHeader
      :title="$t('SCHEDULING.NAV.RESOURCES')"
      :description="$t('SCHEDULING.RESOURCES.DESCRIPTION')"
    >
      <template #actions>
        <Button
          size="sm"
          icon="i-lucide-plus"
          :label="$t('SCHEDULING.RESOURCES.ADD')"
          @click="openCreateResource"
        />
      </template>
    </SchedulingPageHeader>

    <div class="flex flex-col gap-6 p-6">
      <div
        v-if="referencesStore.ui.isLoadingResources"
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

      <SchedulingSectionCard
        v-else
        :title="$t('SCHEDULING.RESOURCES.LIST_TITLE')"
        :description="$t('SCHEDULING.RESOURCES.LIST_DESCRIPTION')"
      >
        <div class="grid gap-4 xl:grid-cols-2">
          <article
            v-for="resource in resourceCards"
            :key="resource.id"
            class="relative overflow-hidden rounded-[28px] outline outline-1 outline-n-container bg-n-surface-1 shadow-sm"
          >
            <div
              class="h-20"
              :style="{
                background: `linear-gradient(135deg, ${resource.color || RESOURCE_COLORS[0]} 0%, ${resource.color || RESOURCE_COLORS[0]}cc 100%)`,
              }"
            />

            <div class="relative flex flex-col gap-4 px-5 pb-5 -mt-8">
              <div class="flex items-start justify-between gap-4">
                <div class="flex items-start gap-3 min-w-0">
                  <Avatar
                    :name="resource.name"
                    :src="profilePhoto(resource)"
                    :size="64"
                    rounded-full
                    class="shadow-sm outline outline-4 outline-n-surface-1"
                  />
                  <div class="flex flex-col min-w-0 gap-1 pt-8">
                    <h3 class="mb-0 text-base font-semibold text-n-slate-12">
                      {{ resource.name }}
                    </h3>
                    <p class="mb-0 text-sm text-n-slate-11">
                      {{
                        resource.specialty ||
                        $t('SCHEDULING.RESOURCES.NO_SPECIALTY')
                      }}
                    </p>
                    <div class="flex flex-wrap items-center gap-2 text-xs">
                      <span
                        class="inline-flex items-center px-2 py-1 rounded-full bg-n-alpha-black2 text-n-slate-11"
                      >
                        {{ resource.timezone }}
                      </span>
                      <span
                        class="inline-flex items-center px-2 py-1 rounded-full bg-n-alpha-black2 text-n-slate-11"
                      >
                        {{ resource.slotDurationMin }}
                        {{ $t('SCHEDULING.GENERAL.MINUTES') }}
                      </span>
                    </div>
                  </div>
                </div>
                <span
                  class="mt-3 px-2 py-1 text-xs rounded-full"
                  :class="
                    resource.active
                      ? 'bg-n-teal-4 text-n-teal-11'
                      : 'bg-n-slate-4 text-n-slate-11'
                  "
                >
                  {{
                    resource.active
                      ? $t('SCHEDULING.GENERAL.ACTIVE')
                      : $t('SCHEDULING.GENERAL.INACTIVE')
                  }}
                </span>
              </div>

              <div class="grid gap-3 md:grid-cols-2">
                <div
                  class="p-3 rounded-2xl bg-n-alpha-black2 text-sm text-n-slate-11"
                >
                  <p
                    class="mb-1 text-xs font-semibold uppercase text-n-slate-10"
                  >
                    {{ $t('SCHEDULING.RESOURCES.LINKED_USER') }}
                  </p>
                  <p class="mb-0 font-medium text-n-slate-12">
                    {{ linkedUser(resource)?.name || '—' }}
                  </p>
                  <p v-if="roleLabel(resource)" class="mb-0 text-xs">
                    {{ roleLabel(resource) }}
                  </p>
                </div>

                <div
                  class="p-3 rounded-2xl bg-n-alpha-black2 text-sm text-n-slate-11"
                >
                  <p
                    class="mb-1 text-xs font-semibold uppercase text-n-slate-10"
                  >
                    {{ $t('SCHEDULING.RESOURCES.COMPENSATION') }}
                  </p>
                  <p class="mb-0 font-medium text-n-slate-12">
                    {{ compensationTypeLabel(resource.compensationType) }}
                  </p>
                  <p class="mb-0 text-xs">
                    {{ resource.compensationValue }}
                  </p>
                </div>
              </div>

              <p
                v-if="resource.description"
                class="mb-0 text-sm leading-6 text-n-slate-11"
              >
                {{ resource.description }}
              </p>

              <span
                class="inline-flex items-center gap-2 text-xs text-n-slate-11"
              >
                <span
                  class="inline-block rounded-full size-3"
                  :style="{
                    backgroundColor: resource.color || RESOURCE_COLORS[0],
                  }"
                />
                {{ resource.color || RESOURCE_COLORS[0] }}
              </span>

              <div class="flex flex-wrap items-center gap-2">
                <Button
                  size="sm"
                  variant="faded"
                  color="slate"
                  :label="$t('SCHEDULING.GENERAL.EDIT')"
                  @click="openEditResource(resource)"
                />
                <Button
                  size="sm"
                  variant="faded"
                  color="slate"
                  :label="$t('SCHEDULING.RESOURCES.EDIT_SCHEDULE')"
                  @click="openScheduleEditor(resource)"
                />
                <Button
                  size="sm"
                  variant="ghost"
                  color="slate"
                  :label="
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
                  :label="$t('SCHEDULING.GENERAL.DELETE')"
                  @click="deleteResource(resource)"
                />
              </div>
            </div>
          </article>
        </div>
      </SchedulingSectionCard>
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
          <div class="grid gap-4 md:grid-cols-2">
            <Input
              v-model="resourceForm.name"
              :label="$t('SCHEDULING.RESOURCES.NAME')"
            />
            <Input
              v-model="resourceForm.specialty"
              :label="$t('SCHEDULING.RESOURCES.SPECIALTY')"
            />
            <ComboBox
              :model-value="resourceForm.userId"
              :options="staffOptions"
              :placeholder="$t('SCHEDULING.RESOURCES.LINKED_USER')"
              @update:model-value="handleUserSelection($event)"
            />
            <Input
              v-model="resourceForm.photoUrl"
              :label="$t('SCHEDULING.RESOURCES.PHOTO_URL')"
            />
            <Input
              v-model="resourceForm.timezone"
              :label="$t('SCHEDULING.RESOURCES.TIMEZONE')"
            />
            <Input
              v-model="resourceForm.slotDurationMin"
              type="number"
              min="5"
              :label="$t('SCHEDULING.RESOURCES.SLOT_DURATION')"
            />
            <ComboBox
              :model-value="resourceForm.compensationType"
              :options="compensationTypeOptions"
              :placeholder="$t('SCHEDULING.RESOURCES.COMPENSATION')"
              @update:model-value="resourceForm.compensationType = $event"
            />
            <Input
              v-model="resourceForm.compensationValue"
              type="number"
              min="0"
              :label="$t('SCHEDULING.GENERAL.VALUE')"
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
                class="size-8 rounded-full border transition-transform hover:scale-105"
                :class="
                  resourceForm.color?.toUpperCase() === color.toUpperCase()
                    ? 'ring-2 ring-offset-2 ring-offset-n-surface-1 ring-n-slate-8 border-n-slate-9'
                    : 'border-n-container'
                "
                :style="{ backgroundColor: color }"
                :aria-label="`${$t('SCHEDULING.RESOURCES.COLOR')} ${color}`"
                :title="color"
                @click="resourceForm.color = color"
              />
            </div>
            <Input
              v-model="resourceForm.color"
              type="color"
              :label="$t('SCHEDULING.RESOURCES.CUSTOM_COLOR')"
            />
          </div>
          <p class="mb-0 text-xs text-n-slate-11">
            {{ $t('SCHEDULING.RESOURCES.LINKED_USER_HELP') }}
          </p>
          <label class="flex items-center gap-3 text-sm text-n-slate-12">
            <input
              v-model="resourceForm.active"
              type="checkbox"
              class="accent-blue-600"
            />
            {{ $t('SCHEDULING.GENERAL.ACTIVE') }}
          </label>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          :title="$t('SCHEDULING.GENERAL.NOTES')"
          :description="$t('SCHEDULING.RESOURCES.DESCRIPTION_HELP')"
        >
          <TextArea
            v-model="resourceForm.description"
            auto-height
            :label="$t('SCHEDULING.GENERAL.DESCRIPTION')"
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
          :tabs="tabs"
          :initial-active-tab="scheduleTab === 'work' ? 0 : 1"
          @tab-changed="scheduleTab = $event.value"
        />

        <div v-if="scheduleTab === 'work'" class="flex flex-col gap-4">
          <div
            v-for="rule in scheduleForm.workRules"
            :key="`work-${rule.weekday}`"
            class="grid items-center gap-4 p-4 rounded-2xl bg-n-alpha-black2 md:grid-cols-[160px_100px_1fr_1fr]"
          >
            <span class="text-sm font-medium text-n-slate-12">
              {{ weekDayLabel(rule.weekday) }}
            </span>
            <label class="flex items-center gap-2 text-sm text-n-slate-11">
              <input
                v-model="rule.active"
                type="checkbox"
                class="accent-blue-600"
              />
              {{ $t('SCHEDULING.GENERAL.ACTIVE') }}
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
          </div>
        </div>

        <div v-else class="flex flex-col gap-4">
          <div
            v-for="rule in scheduleForm.breakRules"
            :key="`break-${rule.weekday}`"
            class="grid items-center gap-4 p-4 rounded-2xl bg-n-alpha-black2 md:grid-cols-[160px_100px_1fr_1fr_1.2fr]"
          >
            <span class="text-sm font-medium text-n-slate-12">
              {{ weekDayLabel(rule.weekday) }}
            </span>
            <label class="flex items-center gap-2 text-sm text-n-slate-11">
              <input
                v-model="rule.active"
                type="checkbox"
                class="accent-blue-600"
              />
              {{ $t('SCHEDULING.GENERAL.ACTIVE') }}
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
          </div>
        </div>
      </div>
    </SchedulingDrawer>
  </section>
</template>
