<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter, useRoute } from 'vue-router';
import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import CrmTasksAPI from 'dashboard/api/crm/tasks';
import {
  normalizePayload,
  normalizeMeta,
  formatCrmErrorMessage,
} from 'dashboard/stores/crm/shared';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { taskStatusLabel } from 'dashboard/components-next/CRM/taskCatalogLabels';
import CrmContactTaskDrawer from './CrmContactTaskDrawer.vue';
import CrmTaskCompletionDialog from './CrmTaskCompletionDialog.vue';
import SidebarActionsHeader from 'dashboard/components-next/SidebarActionsHeader.vue';

const props = defineProps({
  currentChat: { type: Object, required: true },
  contact: { type: Object, required: true },
});
const emit = defineEmits(['close']);
const { t } = useI18n();
const router = useRouter();
const route = useRoute();
const references = useCrmReferencesStore();
const agents = useMapGetter('agents/getAgents');
const tasks = ref([]);
const loading = ref(false);
const saving = ref(false);
const hasMore = ref(false);
const page = ref(0);
const createOpen = ref(false);
const completionDialog = ref(null);
let generation = 0;

const sortedTasks = computed(() =>
  [...tasks.value].sort((a, b) => {
    const aDone = Boolean(a.completedAt || a.cancelledAt);
    const bDone = Boolean(b.completedAt || b.cancelledAt);
    if (aDone !== bDone) return Number(aDone) - Number(bDone);
    return String(a.dueAt || a.dueOn || '').localeCompare(
      String(b.dueAt || b.dueOn || '')
    );
  })
);
const statusLabel = task => {
  const status = references.taskStatuses.find(
    item => Number(item.id) === Number(task.statusId)
  );
  return status ? taskStatusLabel(status, t) : '';
};
const assigneeLabel = task =>
  (agents.value || []).find(item => Number(item.id) === Number(task.assigneeId))
    ?.name || '';
const dueLabel = task => {
  const value = task.dueAt || task.dueOn;
  if (!value) return '';
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? ''
    : new Intl.DateTimeFormat('ru', {
        day: '2-digit',
        month: '2-digit',
        year: 'numeric',
        ...(task.dueAt ? { hour: '2-digit', minute: '2-digit' } : {}),
      }).format(date);
};
const loadTasks = async (nextPage = 1) => {
  if (!props.contact?.id) return;
  generation += 1;
  const request = generation;
  loading.value = true;
  try {
    const { data } = await CrmTasksAPI.get({
      contact_id: props.contact.id,
      page: nextPage,
      per_page: 100,
    });
    if (request !== generation) return;
    tasks.value =
      nextPage === 1
        ? normalizePayload(data)
        : [...tasks.value, ...normalizePayload(data)];
    page.value = nextPage;
    hasMore.value = Boolean(normalizeMeta(data).hasMore);
  } catch (error) {
    if (request === generation) useAlert(formatCrmErrorMessage(error, t));
  } finally {
    if (request === generation) loading.value = false;
  }
};
watch(
  () => props.contact?.id,
  async () => {
    tasks.value = [];
    if (!props.contact?.id) return;
    await Promise.all([
      references.loadTaskStatuses(),
      references.loadTaskTypes(),
      loadTasks(),
    ]);
  },
  { immediate: true }
);
const openTask = task =>
  router.push({
    name: 'crm_tasks_index',
    params: { accountId: route.params.accountId },
    query: { taskId: task.id },
  });
const completeTask = task => completionDialog.value?.open(task);
const saveCompletion = async ({ task, taskOutcomeId, note }) => {
  saving.value = true;
  try {
    await CrmTasksAPI.complete(task.id, {
      task_outcome_id: taskOutcomeId,
      outcome_note: note,
      lock_version: task.lockVersion,
    });
    completionDialog.value?.close();
    await loadTasks();
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  } finally {
    saving.value = false;
  }
};
</script>

<template>
  <div
    class="flex h-full min-w-0 flex-1 flex-col"
    data-test="contact-tasks-panel"
  >
    <SidebarActionsHeader
      :title="t('CRM.TASKS.PANEL_TITLE')"
      @close="emit('close')"
    />
    <div class="min-h-0 flex-1 overflow-y-auto p-3">
      <button
        type="button"
        class="mb-3 w-full rounded-lg border border-n-weak px-3 py-2 text-left text-sm text-n-slate-12 hover:bg-n-alpha-2"
        @click="createOpen = true"
      >
        {{ t('CRM.TASKS.PANEL_ADD') }}
      </button>
      <p v-if="!loading && !tasks.length" class="text-sm text-n-slate-11">
        {{ t('CRM.TASKS.PANEL_EMPTY') }}
      </p>
      <div
        v-for="task in sortedTasks"
        :key="task.id"
        class="mb-2 flex min-w-0 gap-2 rounded-lg border border-n-weak p-2 text-sm"
      >
        <button
          v-if="!task.completedAt && !task.cancelledAt"
          type="button"
          class="size-5 shrink-0 rounded border border-n-strong"
          :aria-label="t('CRM.TASKS.RESULT_DIALOG.ACTION')"
          @click="completeTask(task)"
        />
        <span
          v-else
          class="i-lucide-check size-5 shrink-0 text-n-green-11"
          aria-hidden="true"
        />
        <button
          type="button"
          class="min-w-0 flex-1 text-left"
          @click="openTask(task)"
        >
          <span class="block break-words font-medium text-n-slate-12">{{
            task.title
          }}</span>
          <span class="block text-xs text-n-slate-11">{{
            [dueLabel(task), assigneeLabel(task), statusLabel(task)]
              .filter(Boolean)
              .join(' · ')
          }}</span>
        </button>
      </div>
      <button
        v-if="hasMore && !loading"
        type="button"
        class="text-sm text-n-blue-11"
        @click="loadTasks(page + 1)"
      >
        {{ t('CRM.TASKS.PANEL_MORE') }}
      </button>
    </div>
    <CrmContactTaskDrawer
      v-model="createOpen"
      :contact="contact"
      :current-chat="currentChat"
      @update:model-value="
        value => {
          if (!value) loadTasks();
        }
      "
    />
    <CrmTaskCompletionDialog
      ref="completionDialog"
      :task-types="references.taskTypes"
      :is-loading="saving"
      @confirm="saveCompletion"
    />
  </div>
</template>
