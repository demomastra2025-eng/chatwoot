<script setup>
import { computed, ref } from 'vue';
import Button from 'dashboard/components-next/button/Button.vue';
import SchedulingResourceFilter from './SchedulingResourceFilter.vue';
import SchedulingToolbar from './SchedulingToolbar.vue';
import SchedulingViewSwitcher from './SchedulingViewSwitcher.vue';
import SchedulingVueCalCalendar from './SchedulingVueCalCalendar.vue';
import {
  calendarDayAnchor,
  calendarTodayAnchor,
  formatCalendarTitle,
  shiftAnchorDate,
} from 'dashboard/routes/dashboard/scheduling/helpers';

const workspaceTimezone = 'Asia/Almaty';
const currentView = ref('week');
const currentPresentation = ref('calendar');
const showAllDayEvents = ref(true);
const anchorDate = ref('2026-10-05T07:00:00.000Z');
const selectedResourceIds = ref([12, 13]);
const resources = [
  {
    id: 12,
    name: 'Aida Suleimenova',
    color: '#0f766e',
    slotDurationMin: 30,
  },
  { id: 13, name: 'Sam Kairat', color: '#7c3aed', slotDurationMin: 30 },
];
const appointments = [
  {
    id: 901,
    clientName: 'Alex Doe',
    durationMin: 30,
    endsAt: '2026-10-05T04:30:00.000Z',
    resourceId: 12,
    resourceName: 'Aida Suleimenova',
    serviceNameSnapshot: 'Initial consultation',
    startsAt: '2026-10-05T04:00:00.000Z',
    status: 'confirmed',
  },
  {
    id: 902,
    clientName: 'Dana Omar',
    durationMin: 60,
    endsAt: '2026-10-07T06:00:00.000Z',
    resourceId: 13,
    resourceName: 'Sam Kairat',
    serviceNameSnapshot: 'Follow-up',
    startsAt: '2026-10-07T05:00:00.000Z',
    status: 'scheduled',
  },
];
const views = [
  { label: 'Day', value: 'day' },
  { label: 'Week', value: 'week' },
  { label: 'Month', value: 'month' },
];
const presentationOptions = [
  { icon: 'i-lucide-calendar-days', label: 'Calendar', value: 'calendar' },
  { icon: 'i-lucide-list', label: 'List', value: 'list' },
];
const currentLabel = computed(() =>
  formatCalendarTitle(
    currentView.value,
    anchorDate.value,
    'en',
    workspaceTimezone
  )
);
const selectedResources = computed(() =>
  resources.filter(resource => selectedResourceIds.value.includes(resource.id))
);
const visibleAppointments = computed(() =>
  appointments.filter(appointment =>
    selectedResourceIds.value.includes(appointment.resourceId)
  )
);
const changeAnchor = direction => {
  anchorDate.value = shiftAnchorDate(
    currentView.value,
    anchorDate.value,
    direction,
    workspaceTimezone
  ).toISOString();
};
const selectAnchor = date => {
  anchorDate.value = calendarDayAnchor(date, workspaceTimezone).toISOString();
};
const goToToday = () => {
  anchorDate.value = calendarTodayAnchor(
    new Date(),
    workspaceTimezone
  ).toISOString();
};
</script>

<template>
  <Story
    title="Scheduling/Sticky headers"
    :layout="{ type: 'single', width: '1280px' }"
  >
    <Variant title="Week calendar">
      <div class="flex h-[760px] min-h-0 flex-col bg-n-surface-1">
        <SchedulingToolbar
          v-model="currentView"
          :anchor-date="anchorDate"
          :current-label="currentLabel"
          :views="views"
          show-today
          show-view-switcher
          @previous="changeAnchor(-1)"
          @next="changeAnchor(1)"
          @today="goToToday"
          @select-date="selectAnchor"
        >
          <template #leading>
            <SchedulingViewSwitcher
              v-model="currentPresentation"
              :views="presentationOptions"
              icon-only
            />
          </template>
          <template #actions>
            <SchedulingResourceFilter
              compact
              :resources="resources"
              :model-value="selectedResourceIds"
              @update:model-value="selectedResourceIds = $event"
            />
            <Button
              size="sm"
              color="slate"
              variant="ghost"
              icon="i-lucide-filter"
              aria-label="Filters"
            />
            <Button size="sm" icon="i-lucide-plus" label="New appointment" />
          </template>
        </SchedulingToolbar>

        <main class="flex min-h-0 flex-1 flex-col px-5 pb-4 pt-2">
          <label
            class="mb-2 inline-flex items-center gap-2 text-sm text-n-slate-11"
          >
            <input v-model="showAllDayEvents" type="checkbox" />
            <span>Show all-day row</span>
          </label>
          <SchedulingVueCalCalendar
            class="min-h-0 flex-1"
            :all-day-events="showAllDayEvents"
            :anchor-date="anchorDate"
            :appointments="visibleAppointments"
            read-only
            :resources="selectedResources"
            :view="currentView"
            :workspace-timezone="workspaceTimezone"
          />
        </main>
      </div>
    </Variant>
  </Story>
</template>
