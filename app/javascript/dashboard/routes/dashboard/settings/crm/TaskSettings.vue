<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import Draggable from 'vuedraggable';

import { useAlert } from 'dashboard/composables';
import { usePolicy } from 'dashboard/composables/usePolicy';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingColorPicker from 'dashboard/components-next/Scheduling/SchedulingColorPicker.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { formatCrmErrorMessage } from 'dashboard/stores/crm/shared';
import {
  DEFAULT_TASK_STATUS_COLOR,
  TASK_STATUS_STANDARD_COLORS,
  getUnavailableTaskStatusColors,
  pickTaskStatusColor,
} from 'dashboard/stores/crm/taskStatusColors';

const referencesStore = useCrmReferencesStore();
const route = useRoute();
const router = useRouter();
const { checkPermissions } = usePolicy();
const { t } = useI18n();
const normalizedDefaultTaskStatusColor = String(DEFAULT_TASK_STATUS_COLOR || '')
  .trim()
  .toUpperCase();

const taskStatusDrawerOpen = ref(false);
const taskStatusDeleteDialogRef = ref(null);
const taskStatusPendingDelete = ref(null);
const taskStatusRows = ref([]);
const draggingTaskStatuses = ref(false);
const taskStatusOrderSaving = ref(false);

const canManage = computed(() =>
  checkPermissions(['administrator', 'crm_settings_manage'])
);

const taskStatusForm = reactive({
  active: true,
  category: 'open',
  color: DEFAULT_TASK_STATUS_COLOR,
  id: null,
  name: '',
});

const taskStatusColumns = computed(() => [
  {
    key: 'name',
    label: t('CRM.SETTINGS.TASK_STATUSES.TABLE.NAME'),
    width: '1.3fr',
  },
  {
    key: 'category',
    label: t('CRM.SETTINGS.TASK_STATUSES.TABLE.CATEGORY'),
    width: '0.9fr',
  },
  {
    key: 'default',
    label: t('CRM.SETTINGS.TASK_STATUSES.TABLE.DEFAULT'),
    width: '0.8fr',
  },
  { key: 'actions', label: '', width: '116px', align: 'end' },
]);

const taskStatusGridTemplate = computed(() =>
  taskStatusColumns.value
    .map(column => {
      const width = String(column.width || '1fr');
      return width.endsWith('fr') ? `minmax(0, ${width})` : width;
    })
    .join(' ')
);

const taskStatusCategoryOptions = computed(() => [
  { label: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.open'), value: 'open' },
  {
    label: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.in_progress'),
    value: 'in_progress',
  },
  { label: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.done'), value: 'done' },
]);

const taskStatusCategoryLabel = category => {
  const labelsByCategory = {
    open: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.open'),
    in_progress: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.in_progress'),
    done: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.done'),
  };

  return labelsByCategory[category] || category;
};

const formatErrorMessage = error => formatCrmErrorMessage(error, t);

watch(
  () => referencesStore.taskStatuses,
  taskStatuses => {
    if (draggingTaskStatuses.value || taskStatusOrderSaving.value) {
      return;
    }

    taskStatusRows.value = [...taskStatuses];
  },
  { immediate: true }
);

const canToggleTaskStatusDefault = taskStatus =>
  taskStatus.category === 'open' && taskStatus.active;

const saveInlineTaskStatusDefault = async (taskStatus, nextDefault) => {
  try {
    await referencesStore.saveTaskStatus({
      id: taskStatus.id,
      default: nextDefault,
    });
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const handleTaskStatusDragStart = () => {
  draggingTaskStatuses.value = true;
};

const syncTaskStatusRows = () => {
  taskStatusRows.value = [...referencesStore.taskStatuses];
};

const persistTaskStatusOrder = async () => {
  taskStatusOrderSaving.value = true;

  try {
    const taskStatusUpdates = taskStatusRows.value
      .map((taskStatus, index) => ({
        ...taskStatus,
        nextPosition: index,
      }))
      .filter(
        taskStatus => Number(taskStatus.position) !== taskStatus.nextPosition
      );

    await Promise.all(
      taskStatusUpdates.map(taskStatus =>
        referencesStore.saveTaskStatus({
          id: taskStatus.id,
          position: taskStatus.nextPosition,
        })
      )
    );

    await referencesStore.loadTaskStatuses();
  } catch (error) {
    useAlert(formatErrorMessage(error));
    await referencesStore.loadTaskStatuses();
  } finally {
    taskStatusOrderSaving.value = false;
    draggingTaskStatuses.value = false;
    syncTaskStatusRows();
  }
};

const handleTaskStatusDragEnd = async event => {
  if (event.oldIndex === event.newIndex) {
    draggingTaskStatuses.value = false;
    syncTaskStatusRows();
    return;
  }

  await persistTaskStatusOrder();
};

const defaultTaskStatusColor = ({
  currentTaskStatusId = taskStatusForm.id,
} = {}) => {
  return pickTaskStatusColor(
    referencesStore.taskStatuses,
    TASK_STATUS_STANDARD_COLORS,
    currentTaskStatusId
  );
};

const unavailableTaskStatusStandardColors = computed(
  () =>
    new Set(
      getUnavailableTaskStatusColors(
        referencesStore.taskStatuses,
        TASK_STATUS_STANDARD_COLORS,
        taskStatusForm.id
      )
    )
);

const isTaskStatusStandardColorDisabled = color => {
  const normalizedColor = String(color || '')
    .trim()
    .toUpperCase();

  if (normalizedColor === normalizedDefaultTaskStatusColor) {
    return false;
  }

  return (
    unavailableTaskStatusStandardColors.value.has(normalizedColor) &&
    taskStatusForm.color?.toUpperCase() !== normalizedColor
  );
};

const taskStatusStandardColorAriaLabel = color => {
  const suffix = isTaskStatusStandardColorDisabled(color)
    ? `, ${t('CRM.SETTINGS.TASK_STATUSES.FORM.COLOR_UNAVAILABLE')}`
    : '';

  return `${t('CRM.SETTINGS.TASK_STATUSES.FORM.COLOR')} ${color}${suffix}`;
};

const taskStatusStandardColorTitle = color => {
  if (!isTaskStatusStandardColorDisabled(color)) {
    return color;
  }

  return `${color} · ${t('CRM.SETTINGS.TASK_STATUSES.FORM.COLOR_UNAVAILABLE')}`;
};

const resetTaskStatusForm = () => {
  Object.assign(taskStatusForm, {
    active: true,
    category: 'open',
    color: defaultTaskStatusColor({
      currentTaskStatusId: null,
    }),
    id: null,
    name: '',
  });
};

const openTaskStatusDrawer = taskStatus => {
  if (taskStatus) {
    Object.assign(taskStatusForm, {
      active: taskStatus.active,
      category: taskStatus.category || 'open',
      color:
        taskStatus.color ||
        defaultTaskStatusColor({ currentTaskStatusId: taskStatus.id }),
      id: taskStatus.id,
      name: taskStatus.name,
    });
  } else {
    resetTaskStatusForm();
  }

  taskStatusDrawerOpen.value = true;
};

const openDeleteTaskStatusDialog = taskStatus => {
  if (!taskStatus?.id) return;

  taskStatusPendingDelete.value = taskStatus;
  taskStatusDeleteDialogRef.value?.open();
};

const closeDeleteTaskStatusDialog = () => {
  taskStatusPendingDelete.value = null;
};

const deleteTaskStatus = async () => {
  if (!taskStatusPendingDelete.value) return;

  try {
    await referencesStore.deleteTaskStatus(taskStatusPendingDelete.value);
    taskStatusDeleteDialogRef.value?.close();

    if (
      Number(taskStatusForm.id) === Number(taskStatusPendingDelete.value.id)
    ) {
      taskStatusDrawerOpen.value = false;
      resetTaskStatusForm();
    }

    useAlert(t('CRM.SETTINGS.TASK_STATUSES.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const saveTaskStatus = async () => {
  try {
    await referencesStore.saveTaskStatus({
      active: taskStatusForm.active,
      category: taskStatusForm.category,
      color: taskStatusForm.color,
      id: taskStatusForm.id,
      name: taskStatusForm.name.trim(),
    });
    useAlert(t('CRM.SETTINGS.TASK_STATUSES.SUCCESS_SAVE'));
    taskStatusDrawerOpen.value = false;
    resetTaskStatusForm();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const routeQueryValue = key => {
  const value = route.query[key];
  return Array.isArray(value) ? value[0] : value;
};

const clearRouteActionQuery = async keys => {
  const nextQuery = { ...route.query };
  delete nextQuery.action;
  keys.forEach(key => {
    delete nextQuery[key];
  });

  await router.replace({ query: nextQuery });
};

const consumeRouteAction = async () => {
  if (!canManage.value) {
    return;
  }

  const action = routeQueryValue('action');

  if (action === 'create-task-status') {
    openTaskStatusDrawer();
    await clearRouteActionQuery([]);
  }
};

onMounted(async () => {
  await referencesStore.loadTaskStatuses();
  resetTaskStatusForm();
  await consumeRouteAction();
});
</script>

<template>
  <SettingsLayout
    :is-loading="referencesStore.ui.isLoadingTaskStatuses"
    :loading-message="$t('CRM.SETTINGS.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="$t('CRM.SETTINGS.TASK_SETTINGS.TITLE')"
        :description="$t('CRM.SETTINGS.TASK_SETTINGS.DESCRIPTION')"
      />
    </template>

    <template #loading>
      <div class="flex justify-center py-16">
        <Spinner class="!h-8 !w-8" />
      </div>
    </template>

    <template #body>
      <div class="grid gap-10">
        <SchedulingErrorState
          v-if="referencesStore.ui.error"
          :title="$t('CRM.ERRORS.LOAD_TITLE')"
          :description="formatErrorMessage(referencesStore.ui.error)"
          @retry="$router.go(0)"
        />

        <SchedulingFormFieldGroup
          :framed="false"
          :title="$t('CRM.SETTINGS.TASK_STATUSES.TITLE')"
          :description="$t('CRM.SETTINGS.TASK_STATUSES.DESCRIPTION')"
        >
          <div
            class="mt-3 overflow-hidden rounded-2xl bg-n-solid-2 outline outline-1 outline-n-container shadow-sm"
          >
            <div
              class="grid border-b border-n-weak bg-n-surface-2/80 px-5 py-3 text-[11px] font-semibold uppercase tracking-[0.08em] text-n-slate-10 backdrop-blur"
              :style="{ gridTemplateColumns: taskStatusGridTemplate }"
            >
              <div
                v-for="column in taskStatusColumns"
                :key="column.key"
                class="min-w-0 truncate"
                :class="[column.align === 'end' ? 'text-end' : 'text-start']"
              >
                {{ column.label }}
              </div>
            </div>

            <div
              v-if="taskStatusRows.length === 0"
              class="px-5 py-10 text-sm text-center text-n-slate-11"
            >
              {{ $t('SCHEDULING.GENERAL.NO_DATA') }}
            </div>

            <Draggable
              v-else
              v-model="taskStatusRows"
              item-key="id"
              handle=".task-status-drag-handle"
              :disabled="!canManage || taskStatusOrderSaving"
              animation="200"
              ghost-class="pipeline-ghost"
              class="divide-y divide-n-weak"
              @start="handleTaskStatusDragStart"
              @end="handleTaskStatusDragEnd"
            >
              <template #item="{ element: row }">
                <div
                  class="grid items-center gap-3 px-5 py-3 text-sm text-n-slate-12 transition-colors hover:bg-n-alpha-1"
                  :style="{ gridTemplateColumns: taskStatusGridTemplate }"
                >
                  <div class="min-w-0">
                    <div class="flex items-start gap-3">
                      <button
                        type="button"
                        class="task-status-drag-handle mt-0.5 inline-flex size-10 shrink-0 items-center justify-center rounded-lg transition-colors"
                        :class="
                          canManage && !taskStatusOrderSaving
                            ? 'cursor-grab text-n-slate-10 hover:bg-n-alpha-black2 hover:text-n-slate-12 active:cursor-grabbing'
                            : 'cursor-default text-n-slate-8'
                        "
                        :disabled="!canManage || taskStatusOrderSaving"
                        :title="$t('CRM.SETTINGS.TASK_STATUSES.DRAG')"
                      >
                        <span
                          class="i-lucide-grip-vertical size-5"
                          aria-hidden="true"
                        />
                      </button>

                      <div class="min-w-0 flex-1 grid gap-1">
                        <span
                          class="inline-flex min-w-0 items-center gap-2 font-medium text-n-slate-12"
                        >
                          <span
                            class="size-2.5 shrink-0 rounded-full outline outline-1 outline-black/10 dark:outline-white/10"
                            :style="{
                              backgroundColor:
                                row.color || DEFAULT_TASK_STATUS_COLOR,
                            }"
                          />
                          <span class="truncate">{{ row.name }}</span>
                        </span>
                      </div>
                    </div>
                  </div>

                  <div class="min-w-0">
                    <span class="text-sm text-n-slate-12">
                      {{ taskStatusCategoryLabel(row.category) }}
                    </span>
                  </div>

                  <div class="min-w-0">
                    <div class="flex justify-start">
                      <Switch
                        :model-value="row.default"
                        :disabled="
                          !canManage ||
                          !canToggleTaskStatusDefault(row) ||
                          taskStatusOrderSaving ||
                          referencesStore.ui.isSaving
                        "
                        @update:model-value="
                          saveInlineTaskStatusDefault(row, $event)
                        "
                      />
                    </div>
                  </div>

                  <div class="min-w-0 text-end">
                    <div v-if="canManage" class="flex justify-end gap-1">
                      <Button
                        size="sm"
                        color="slate"
                        variant="ghost"
                        icon="i-lucide-pen-line"
                        @click="openTaskStatusDrawer(row)"
                      />
                      <Button
                        size="sm"
                        color="ruby"
                        variant="ghost"
                        icon="i-lucide-trash"
                        @click="openDeleteTaskStatusDialog(row)"
                      />
                    </div>
                  </div>
                </div>
              </template>
            </Draggable>
          </div>

          <template #headerActions>
            <Button
              v-if="canManage"
              size="sm"
              icon="i-lucide-plus"
              :label="$t('CRM.SETTINGS.TASK_STATUSES.ADD')"
              @click="openTaskStatusDrawer()"
            />
          </template>
        </SchedulingFormFieldGroup>
      </div>
    </template>

    <Dialog
      ref="taskStatusDeleteDialogRef"
      width="md"
      type="alert"
      :title="$t('CRM.SETTINGS.TASK_STATUSES.DELETE_TITLE')"
      :description="
        $t('CRM.SETTINGS.TASK_STATUSES.DELETE_DESCRIPTION', {
          name: taskStatusPendingDelete?.name || '',
        })
      "
      :confirm-button-label="$t('CRM.SETTINGS.TASK_STATUSES.DELETE_CONFIRM')"
      :is-loading="referencesStore.ui.isSaving"
      @close="closeDeleteTaskStatusDialog"
      @confirm="deleteTaskStatus"
    />

    <SchedulingDrawer
      v-model="taskStatusDrawerOpen"
      width="sm"
      :title="
        taskStatusForm.id
          ? $t('CRM.SETTINGS.TASK_STATUSES.EDIT_TITLE')
          : $t('CRM.SETTINGS.TASK_STATUSES.CREATE_TITLE')
      "
      :confirm-label="$t('CRM.GENERAL.SAVE')"
      :is-loading="referencesStore.ui.isSaving"
      :disable-confirm="!taskStatusForm.name.trim()"
      @confirm="saveTaskStatus"
    >
      <div class="mx-auto grid w-full max-w-[26rem] gap-4">
        <Input
          :label="$t('CRM.SETTINGS.TASK_STATUSES.FORM.NAME')"
          :model-value="taskStatusForm.name"
          @update:model-value="taskStatusForm.name = $event"
        />
        <div class="grid gap-3">
          <span class="text-sm font-medium text-n-slate-12">
            {{ $t('CRM.SETTINGS.TASK_STATUSES.FORM.COLOR') }}
          </span>
          <div class="flex flex-wrap gap-2">
            <button
              v-for="color in TASK_STATUS_STANDARD_COLORS"
              :key="color"
              type="button"
              class="relative size-8 rounded-full border-2 transition-transform hover:scale-105 disabled:cursor-not-allowed disabled:opacity-100 disabled:hover:scale-100"
              :class="[
                taskStatusForm.color?.toUpperCase() === color.toUpperCase()
                  ? 'ring-2 ring-offset-2 ring-offset-n-surface-1 ring-n-slate-8 border-n-slate-9'
                  : 'border-n-container',
                isTaskStatusStandardColorDisabled(color)
                  ? 'border-n-slate-8 shadow-[inset_0_0_0_1px_rgba(15,23,42,0.08)]'
                  : '',
              ]"
              :style="{ backgroundColor: color }"
              :disabled="isTaskStatusStandardColorDisabled(color)"
              :aria-label="taskStatusStandardColorAriaLabel(color)"
              :title="taskStatusStandardColorTitle(color)"
              @click="taskStatusForm.color = color"
            >
              <span
                v-if="isTaskStatusStandardColorDisabled(color)"
                class="pointer-events-none absolute -bottom-0.5 -right-0.5 flex size-4 items-center justify-center rounded-full bg-n-surface-1 text-n-slate-12 outline outline-1 outline-n-container shadow-sm"
                aria-hidden="true"
              >
                <span class="size-2.5 i-lucide-slash" />
              </span>
            </button>
          </div>
          <div class="grid gap-2 md:max-w-xs">
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('CRM.SETTINGS.TASK_STATUSES.FORM.CUSTOM_COLOR') }}
            </span>
            <SchedulingColorPicker v-model="taskStatusForm.color" />
          </div>
        </div>
        <SchedulingSelectField
          :label="$t('CRM.SETTINGS.TASK_STATUSES.FORM.CATEGORY')"
          :model-value="taskStatusForm.category"
          :options="taskStatusCategoryOptions"
          @update:model-value="taskStatusForm.category = $event"
        />
        <div v-if="taskStatusForm.id" class="flex items-center gap-3">
          <Checkbox
            :model-value="!taskStatusForm.active"
            @update:model-value="taskStatusForm.active = !$event"
          />
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM.SETTINGS.TASK_STATUSES.FORM.DEACTIVATE') }}
          </span>
        </div>
      </div>
    </SchedulingDrawer>
  </SettingsLayout>
</template>

<style scoped lang="scss">
.pipeline-ghost {
  @apply opacity-50 bg-n-slate-3 dark:bg-n-slate-9;
}
</style>
