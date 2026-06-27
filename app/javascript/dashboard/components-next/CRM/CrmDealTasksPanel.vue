<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { format } from 'date-fns';
import { useI18n } from 'vue-i18n';

import CrmTasksAPI from 'dashboard/api/crm/tasks';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import CrmTaskAssigneeMenu from 'dashboard/components-next/CRM/CrmTaskAssigneeMenu.vue';
import CrmTaskPriorityMenu from 'dashboard/components-next/CRM/CrmTaskPriorityMenu.vue';
import CrmTaskStatusMenu from 'dashboard/components-next/CRM/CrmTaskStatusMenu.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import {
  buildDefaultCustomAttributes,
  mergeMissingDefaultCustomAttributes,
} from 'dashboard/stores/crm/customFieldDefaults';
import {
  compactPayload,
  formatCrmErrorMessage,
  normalizePayload,
} from 'dashboard/stores/crm/shared';

const props = defineProps({
  assignees: {
    type: Array,
    default: () => [],
  },
  canManageTasks: {
    type: Boolean,
    default: false,
  },
  deal: {
    type: Object,
    default: null,
  },
  statuses: {
    type: Array,
    default: () => [],
  },
  taskFieldDefinitions: {
    type: Array,
    default: () => [],
  },
  teamOptions: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['created', 'updated']);
const { t } = useI18n();

const createTaskDialogRef = ref(null);
const tasks = ref([]);
const ui = reactive({
  isLoading: false,
  isSaving: false,
});
const form = reactive({
  assigneeId: '',
  customAttributes: {},
  description: '',
  dueAt: '',
  priority: 'medium',
  startAt: '',
  statusId: '',
  teamId: '',
  title: '',
});

const priorityOptions = computed(() => [
  { label: t('CRM.TASKS.PRIORITY.low'), value: 'low' },
  { label: t('CRM.TASKS.PRIORITY.medium'), value: 'medium' },
  { label: t('CRM.TASKS.PRIORITY.high'), value: 'high' },
  { label: t('CRM.TASKS.PRIORITY.urgent'), value: 'urgent' },
]);

const defaultStatus = computed(
  () =>
    props.statuses.find(status => status.default) ||
    props.statuses.find(status => status.category === 'open') ||
    props.statuses[0]
);

const applicableTaskFieldDefinitions = computed(() =>
  props.taskFieldDefinitions.filter(definition => {
    const contexts = definition.rules?.contexts || [];
    return contexts.length === 0 || contexts.includes('deal_task');
  })
);

const taskStatusById = computed(() =>
  props.statuses.reduce((result, status) => {
    result[Number(status.id)] = status;
    return result;
  }, {})
);

const taskStatusCategory = task =>
  taskStatusById.value[Number(task.statusId)]?.category || 'open';

const sortedTasks = computed(() =>
  [...tasks.value].sort((left, right) => {
    const leftDone = taskStatusCategory(left) === 'done' ? 1 : 0;
    const rightDone = taskStatusCategory(right) === 'done' ? 1 : 0;

    if (leftDone !== rightDone) return leftDone - rightDone;

    const leftDate = new Date(
      left.dueAt || left.updatedAt || left.createdAt || 0
    );
    const rightDate = new Date(
      right.dueAt || right.updatedAt || right.createdAt || 0
    );

    return leftDate - rightDate;
  })
);

const hasDeal = computed(() => !!props.deal?.id);
const canCreateTask = computed(() => props.canManageTasks && hasDeal.value);
const isCreateDisabled = computed(
  () => !form.title.trim() || !form.statusId || !hasDeal.value
);

const buildCreateTaskTitle = () =>
  t('CRM.TASKS.PREFILL.DEAL', {
    dealTitle: props.deal?.title || `#${props.deal?.id}`,
  });

const resetForm = () => {
  Object.assign(form, {
    assigneeId: props.deal?.ownerId || '',
    customAttributes: buildDefaultCustomAttributes(
      applicableTaskFieldDefinitions.value
    ),
    description: '',
    dueAt: '',
    priority: 'medium',
    startAt: '',
    statusId: defaultStatus.value?.id || '',
    teamId: props.deal?.teamId || '',
    title: buildCreateTaskTitle(),
  });
};

const upsertTask = task => {
  const index = tasks.value.findIndex(
    item => Number(item.id) === Number(task.id)
  );
  const nextTasks = [...tasks.value];

  if (index === -1) {
    nextTasks.unshift(task);
  } else {
    nextTasks.splice(index, 1, task);
  }

  tasks.value = nextTasks;
};

const loadTasks = async () => {
  if (!hasDeal.value) {
    tasks.value = [];
    return;
  }

  ui.isLoading = true;

  try {
    const { data } = await CrmTasksAPI.get({
      archived: false,
      deal_id: props.deal.id,
    });
    tasks.value = normalizePayload(data);
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  } finally {
    ui.isLoading = false;
  }
};

const buildPayload = () =>
  compactPayload({
    assignee_id: form.assigneeId ? Number(form.assigneeId) : undefined,
    custom_attributes: form.customAttributes,
    deal_id: Number(props.deal.id),
    description: form.description || undefined,
    due_at: form.dueAt || undefined,
    priority: form.priority || undefined,
    start_at: form.startAt || undefined,
    status_id: form.statusId ? Number(form.statusId) : undefined,
    team_id: form.teamId ? Number(form.teamId) : undefined,
    title: form.title.trim(),
  });

const openCreateTaskDialog = () => {
  if (!canCreateTask.value) return;

  resetForm();
  createTaskDialogRef.value?.open();
};

const closeCreateTaskDialog = () => {
  createTaskDialogRef.value?.close();
};

const createTask = async () => {
  if (isCreateDisabled.value) return;

  ui.isSaving = true;

  try {
    const { data } = await CrmTasksAPI.create(buildPayload());
    const task = normalizePayload(data);
    upsertTask(task);
    emit('created', task);
    useAlert(t('CRM.TASKS.SUCCESS_CREATED'));
    closeCreateTaskDialog();
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  } finally {
    ui.isSaving = false;
  }
};

const changeTaskStatus = async (task, statusId) => {
  if (!props.canManageTasks) return;

  try {
    const { data } = await CrmTasksAPI.changeStatus(task.id, {
      lock_version: task.lockVersion,
      status_id: Number(statusId),
    });
    const updatedTask = normalizePayload(data);
    upsertTask(updatedTask);
    emit('updated', updatedTask);
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  }
};

const updateTask = async (task, payload) => {
  if (!props.canManageTasks) return;

  try {
    const { data } = await CrmTasksAPI.update(task.id, {
      ...payload,
      lock_version: task.lockVersion,
    });
    const updatedTask = normalizePayload(data);
    upsertTask(updatedTask);
    emit('updated', updatedTask);
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  }
};

const changeTaskAssignee = (task, assigneeId) => {
  updateTask(task, {
    assignee_id: assigneeId ? Number(assigneeId) : undefined,
  });
};

const changeTaskPriority = (task, priority) => {
  updateTask(task, { priority });
};

const formatDate = value => {
  if (!value) return '';
  return format(new Date(value), 'MMM d, yyyy HH:mm');
};

const taskDateSummary = task => {
  if (task.dueAt) {
    return t('CRM.DEALS.TASKS.DUE_AT', { date: formatDate(task.dueAt) });
  }

  if (task.startAt) {
    return t('CRM.DEALS.TASKS.START_AT', { date: formatDate(task.startAt) });
  }

  return '';
};

watch(
  () => props.deal?.id,
  () => {
    loadTasks();
  },
  { immediate: true }
);

watch(applicableTaskFieldDefinitions, definitions => {
  if (!definitions.length) return;

  form.customAttributes = mergeMissingDefaultCustomAttributes(
    form.customAttributes,
    definitions
  );
});

defineExpose({ openCreateTaskDialog, loadTasks });
</script>

<template>
  <section
    class="overflow-hidden rounded-2xl border border-n-weak bg-n-solid-1 shadow-sm"
  >
    <header
      class="flex items-center justify-between gap-3 border-b border-n-weak px-4 py-3"
    >
      <div class="flex min-w-0 items-center gap-3">
        <span
          class="flex size-8 shrink-0 items-center justify-center rounded-xl bg-n-blue-3 text-n-blue-11"
        >
          <Icon icon="i-lucide-list-checks" class="size-4" />
        </span>
        <div class="grid min-w-0 gap-0.5">
          <h4 class="mb-0 truncate text-sm font-medium text-n-slate-12">
            {{ $t('CRM.DEALS.TASKS.TITLE') }}
          </h4>
          <p class="mb-0 truncate text-xs text-n-slate-10">
            {{ $t('CRM.DEALS.TASKS.COUNT', { count: tasks.length }) }}
          </p>
        </div>
      </div>

      <Button
        v-if="canManageTasks"
        size="sm"
        color="slate"
        variant="ghost"
        icon="i-lucide-plus"
        :label="$t('CRM.DEALS.TASKS.ADD')"
        :disabled="!hasDeal"
        @click="openCreateTaskDialog"
      />
    </header>

    <div
      v-if="ui.isLoading"
      class="px-4 py-6 text-center text-sm text-n-slate-11"
    >
      {{ $t('CRM.DEALS.TASKS.LOADING') }}
    </div>

    <div
      v-else-if="sortedTasks.length === 0"
      class="grid place-items-center gap-3 px-4 py-8 text-center"
    >
      <span
        class="flex size-10 items-center justify-center rounded-2xl bg-n-alpha-black2 text-n-slate-11"
      >
        <Icon icon="i-lucide-list-checks" class="size-5" />
      </span>
      <div class="grid gap-1">
        <p class="mb-0 text-sm font-medium text-n-slate-12">
          {{ $t('CRM.DEALS.TASKS.EMPTY_TITLE') }}
        </p>
        <p class="mb-0 text-sm text-n-slate-11">
          {{ $t('CRM.DEALS.TASKS.EMPTY_DESCRIPTION') }}
        </p>
      </div>
      <Button
        v-if="canManageTasks"
        size="sm"
        icon="i-lucide-plus"
        :label="$t('CRM.DEALS.TASKS.ADD')"
        :disabled="!hasDeal"
        @click="openCreateTaskDialog"
      />
    </div>

    <ol v-else class="divide-y divide-n-weak">
      <li
        v-for="task in sortedTasks"
        :key="task.id"
        class="grid gap-3 px-4 py-3 transition-colors hover:bg-n-alpha-black2/70"
      >
        <div class="flex min-w-0 items-start justify-between gap-3">
          <div class="grid min-w-0 gap-1">
            <h4 class="mb-0 truncate text-sm font-medium text-n-slate-12">
              {{ task.title }}
            </h4>
            <p
              v-if="task.description"
              class="mb-0 line-clamp-2 whitespace-pre-wrap text-xs leading-4 text-n-slate-11"
            >
              {{ task.description }}
            </p>
            <p
              v-if="taskDateSummary(task)"
              class="mb-0 text-xs text-n-slate-10"
            >
              {{ taskDateSummary(task) }}
            </p>
          </div>

          <CrmTaskStatusMenu
            :model-value="task.statusId"
            :statuses="statuses"
            :disabled="!canManageTasks"
            neutral
            @update:model-value="changeTaskStatus(task, $event)"
          />
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <CrmTaskPriorityMenu
            :model-value="task.priority || 'medium'"
            :options="priorityOptions"
            :disabled="!canManageTasks"
            @update:model-value="changeTaskPriority(task, $event)"
          />
          <CrmTaskAssigneeMenu
            :model-value="task.assigneeId"
            :assignees="assignees"
            :disabled="!canManageTasks"
            @update:model-value="changeTaskAssignee(task, $event)"
          />
          <span
            v-if="task.archivedAt"
            class="rounded-full bg-n-amber-3 px-2 py-0.5 text-[10px] font-medium text-n-amber-11"
          >
            {{ $t('CRM.GENERAL.ARCHIVED') }}
          </span>
        </div>
      </li>
    </ol>
  </section>

  <Dialog
    ref="createTaskDialogRef"
    width="2xl"
    overflow-y-auto
    :title="$t('CRM.TASKS.CREATE_TITLE')"
    :description="$t('CRM.DEALS.TASKS.CREATE_DESCRIPTION')"
    :confirm-button-label="$t('CRM.GENERAL.CREATE')"
    :disable-confirm-button="isCreateDisabled"
    :is-loading="ui.isSaving"
    @confirm="createTask"
  >
    <div class="grid gap-4">
      <Input
        :label="$t('CRM.TASKS.FORM.TITLE')"
        :model-value="form.title"
        size="sm"
        @update:model-value="form.title = $event"
      />

      <div class="grid gap-3 md:grid-cols-2">
        <SchedulingSelectField
          :label="$t('CRM.TASKS.FORM.STATUS')"
          :model-value="form.statusId"
          :options="
            statuses.map(status => ({ label: status.name, value: status.id }))
          "
          dropdown-placement="auto"
          @update:model-value="form.statusId = $event"
        />
        <SchedulingSelectField
          :label="$t('CRM.TASKS.FORM.ASSIGNEE')"
          :model-value="form.assigneeId"
          :options="assignees"
          dropdown-placement="auto"
          @update:model-value="form.assigneeId = $event"
        />
      </div>

      <div class="grid gap-3 md:grid-cols-2">
        <SchedulingDateTimeField
          :label="$t('CRM.TASKS.FORM.START_AT')"
          :model-value="form.startAt"
          type="datetime"
          @update:model-value="form.startAt = $event"
        />
        <SchedulingDateTimeField
          :label="$t('CRM.TASKS.FORM.DUE_AT')"
          :model-value="form.dueAt"
          type="datetime"
          @update:model-value="form.dueAt = $event"
        />
      </div>

      <div class="grid gap-3 md:grid-cols-2">
        <SchedulingSelectField
          :label="$t('CRM.TASKS.FORM.PRIORITY')"
          :model-value="form.priority"
          :options="priorityOptions"
          dropdown-placement="auto"
          @update:model-value="form.priority = $event"
        />
        <SchedulingSelectField
          v-if="teamOptions.length || form.teamId"
          :label="$t('CRM.TASKS.FORM.TEAM')"
          :model-value="form.teamId"
          :options="teamOptions"
          dropdown-placement="auto"
          @update:model-value="form.teamId = $event"
        />
      </div>

      <TextArea
        :label="$t('CRM.TASKS.FORM.DESCRIPTION')"
        :model-value="form.description"
        auto-height
        custom-text-area-wrapper-class="!rounded-md !border-n-weak !bg-n-alpha-black2 !px-3 !py-2 hover:!border-n-slate-6"
        min-height="4rem"
        max-height="none"
        @update:model-value="form.description = $event"
      />

      <CrmCustomFieldsSection
        v-if="applicableTaskFieldDefinitions.length"
        :definitions="applicableTaskFieldDefinitions"
        :framed="false"
        layout="rows"
        :model-value="form.customAttributes"
        @update:model-value="form.customAttributes = $event"
      />
    </div>
  </Dialog>
</template>
