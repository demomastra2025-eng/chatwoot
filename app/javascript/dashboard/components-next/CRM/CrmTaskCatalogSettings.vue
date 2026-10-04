<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { useAlert } from 'dashboard/composables';
import { formatCrmErrorMessage } from 'dashboard/stores/crm/shared';
import { CRM_TASK_TYPE_ICONS, normalizeCrmTaskTypeIcon } from './taskTypeIcons';

const props = defineProps({
  canManage: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();
const referencesStore = useCrmReferencesStore();
const typeDialogRef = ref(null);
const outcomeDialogRef = ref(null);
const selectedTaskType = ref(null);
const typeForm = reactive({
  active: true,
  default: false,
  icon: 'i-lucide-list-todo',
  id: null,
  name: '',
});
const outcomeForm = reactive({
  active: true,
  default: false,
  id: null,
  name: '',
  requiresNote: false,
  taskTypeId: null,
});

const taskTypes = computed(() => referencesStore.taskTypes);
const typeFormDisabled = computed(
  () =>
    !props.canManage ||
    referencesStore.ui.isSavingTaskCatalog ||
    !typeForm.name.trim()
);
const outcomeFormDisabled = computed(
  () =>
    !props.canManage ||
    referencesStore.ui.isSavingTaskCatalog ||
    !outcomeForm.name.trim()
);

const openTypeDialog = (taskType = null) => {
  Object.assign(typeForm, {
    active: taskType?.active ?? true,
    default: taskType?.default ?? false,
    icon: normalizeCrmTaskTypeIcon(taskType?.icon),
    id: taskType?.id || null,
    name: taskType?.name || '',
  });
  typeDialogRef.value?.open();
};

const openOutcomeDialog = (taskType, outcome = null) => {
  selectedTaskType.value = taskType;
  Object.assign(outcomeForm, {
    active: outcome?.active ?? true,
    default: outcome?.default ?? false,
    id: outcome?.id || null,
    name: outcome?.name || '',
    requiresNote: outcome?.requiresNote ?? false,
    taskTypeId: taskType.id,
  });
  outcomeDialogRef.value?.open();
};

const saveTaskType = async () => {
  if (!props.canManage || typeFormDisabled.value) return;

  try {
    const saved = await referencesStore.saveTaskType({
      active: typeForm.active,
      default: typeForm.default,
      icon: typeForm.icon,
      id: typeForm.id,
      name: typeForm.name.trim(),
    });
    if (!saved) return;
    typeDialogRef.value?.close();
    useAlert(t('CRM.SETTINGS.TASK_CATALOGS.SAVED'));
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  }
};

const saveTaskOutcome = async () => {
  if (!props.canManage || outcomeFormDisabled.value) return;

  try {
    const saved = await referencesStore.saveTaskOutcome({
      active: outcomeForm.active,
      default: outcomeForm.default,
      id: outcomeForm.id,
      name: outcomeForm.name.trim(),
      requires_note: outcomeForm.requiresNote,
      task_type_id: outcomeForm.taskTypeId,
    });
    if (!saved) return;
    outcomeDialogRef.value?.close();
    useAlert(t('CRM.SETTINGS.TASK_CATALOGS.SAVED'));
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  }
};

const toggleTaskType = async taskType => {
  if (!props.canManage || referencesStore.ui.isSavingTaskCatalog) return;
  try {
    await referencesStore.saveTaskType({
      active: !taskType.active,
      id: taskType.id,
    });
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  }
};
</script>

<template>
  <section>
    <div class="mb-4 flex flex-wrap items-start justify-between gap-3">
      <div>
        <h3 class="mb-1 text-base font-semibold text-n-slate-12">
          {{ t('CRM.SETTINGS.TASK_CATALOGS.TITLE') }}
        </h3>
        <p class="mb-0 text-sm text-n-slate-11">
          {{ t('CRM.SETTINGS.TASK_CATALOGS.DESCRIPTION') }}
        </p>
      </div>
      <Button
        v-if="canManage"
        size="sm"
        icon="i-lucide-plus"
        :label="t('CRM.SETTINGS.TASK_CATALOGS.ADD_TYPE')"
        @click="openTypeDialog()"
      />
    </div>

    <div class="grid gap-3">
      <article
        v-for="taskType in taskTypes"
        :key="taskType.id"
        class="rounded-xl border border-n-weak bg-n-alpha-white1 p-4"
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex min-w-0 items-center gap-3">
            <span
              class="size-5 shrink-0 text-n-slate-11"
              :class="taskType.icon"
            />
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-medium text-n-slate-12">{{
                  taskType.name
                }}</span>
                <span
                  v-if="taskType.default"
                  class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-xs text-n-slate-11"
                >
                  {{ t('CRM.SETTINGS.TASK_CATALOGS.DEFAULT') }}
                </span>
                <span
                  v-if="!taskType.active"
                  class="rounded-full bg-n-ruby-3 px-2 py-0.5 text-xs text-n-ruby-11"
                >
                  {{ t('CRM.SETTINGS.TASK_CATALOGS.INACTIVE') }}
                </span>
              </div>
              <span class="text-xs text-n-slate-10">{{ taskType.code }}</span>
            </div>
          </div>
          <div v-if="canManage" class="flex items-center gap-2">
            <Button
              size="xs"
              color="slate"
              variant="ghost"
              icon="i-lucide-pencil"
              :label="t('CRM.GENERAL.EDIT')"
              @click="openTypeDialog(taskType)"
            />
            <Button
              size="xs"
              color="slate"
              variant="ghost"
              :label="
                taskType.active
                  ? t('CRM.SETTINGS.TASK_CATALOGS.DEACTIVATE')
                  : t('CRM.SETTINGS.TASK_CATALOGS.ACTIVATE')
              "
              @click="toggleTaskType(taskType)"
            />
          </div>
        </div>

        <div class="mt-3 flex flex-wrap gap-2">
          <button
            v-for="outcome in taskType.outcomes"
            :key="outcome.id"
            type="button"
            class="rounded-lg border border-n-weak px-2.5 py-1.5 text-xs text-n-slate-11 hover:bg-n-alpha-2"
            :class="{ 'opacity-50': !outcome.active }"
            :disabled="!canManage"
            @click="openOutcomeDialog(taskType, outcome)"
          >
            {{ outcome.name }}
            <span
              v-if="outcome.requiresNote"
              class="i-lucide-asterisk ml-0.5 inline-block size-3"
              aria-hidden="true"
            />
          </button>
          <Button
            v-if="canManage"
            size="xs"
            color="slate"
            variant="ghost"
            icon="i-lucide-plus"
            :label="t('CRM.SETTINGS.TASK_CATALOGS.ADD_OUTCOME')"
            @click="openOutcomeDialog(taskType)"
          />
        </div>
      </article>
    </div>

    <Dialog
      ref="typeDialogRef"
      width="lg"
      :title="
        typeForm.id
          ? t('CRM.SETTINGS.TASK_CATALOGS.EDIT_TYPE')
          : t('CRM.SETTINGS.TASK_CATALOGS.ADD_TYPE')
      "
      :confirm-button-label="t('CRM.GENERAL.SAVE')"
      :disable-confirm-button="typeFormDisabled"
      :is-loading="referencesStore.ui.isSavingTaskCatalog"
      @confirm="saveTaskType"
    >
      <div class="grid gap-4">
        <Input
          :label="t('CRM.SETTINGS.TASK_CATALOGS.NAME')"
          :model-value="typeForm.name"
          @update:model-value="typeForm.name = $event"
        />
        <fieldset>
          <legend class="mb-2 text-sm font-medium text-n-slate-12">
            {{ t('CRM.SETTINGS.TASK_CATALOGS.ICON') }}
          </legend>
          <div class="grid grid-cols-6 gap-2 sm:grid-cols-8">
            <button
              v-for="(icon, index) in CRM_TASK_TYPE_ICONS"
              :key="icon"
              type="button"
              class="relative flex size-10 items-center justify-center rounded-lg border text-n-slate-11 transition-colors hover:bg-n-alpha-2"
              :class="
                typeForm.icon === icon
                  ? 'border-n-brand bg-n-brand-alpha-2 text-n-brand'
                  : 'border-n-weak bg-n-alpha-white1'
              "
              :aria-label="
                t('CRM.SETTINGS.TASK_CATALOGS.ICON_OPTION', {
                  number: index + 1,
                })
              "
              :aria-pressed="typeForm.icon === icon"
              @click="typeForm.icon = icon"
            >
              <span class="size-5" :class="icon" aria-hidden="true" />
              <span
                v-if="typeForm.icon === icon"
                class="i-lucide-check absolute right-0.5 top-0.5 size-3 text-n-brand"
                aria-hidden="true"
              />
            </button>
          </div>
        </fieldset>
        <label class="flex items-center gap-3 text-sm text-n-slate-12">
          <Switch v-model="typeForm.default" />
          {{ t('CRM.SETTINGS.TASK_CATALOGS.DEFAULT') }}
        </label>
        <label class="flex items-center gap-3 text-sm text-n-slate-12">
          <Switch v-model="typeForm.active" />
          {{ t('CRM.SETTINGS.TASK_CATALOGS.ACTIVE') }}
        </label>
      </div>
    </Dialog>

    <Dialog
      ref="outcomeDialogRef"
      width="lg"
      :title="
        outcomeForm.id
          ? t('CRM.SETTINGS.TASK_CATALOGS.EDIT_OUTCOME')
          : t('CRM.SETTINGS.TASK_CATALOGS.ADD_OUTCOME')
      "
      :confirm-button-label="t('CRM.GENERAL.SAVE')"
      :disable-confirm-button="outcomeFormDisabled"
      :is-loading="referencesStore.ui.isSavingTaskCatalog"
      @confirm="saveTaskOutcome"
    >
      <div class="grid gap-4">
        <Input
          :label="t('CRM.SETTINGS.TASK_CATALOGS.NAME')"
          :model-value="outcomeForm.name"
          @update:model-value="outcomeForm.name = $event"
        />
        <label class="flex items-center gap-3 text-sm text-n-slate-12">
          <Switch v-model="outcomeForm.default" />
          {{ t('CRM.SETTINGS.TASK_CATALOGS.DEFAULT') }}
        </label>
        <label class="flex items-center gap-3 text-sm text-n-slate-12">
          <Switch v-model="outcomeForm.requiresNote" />
          {{ t('CRM.SETTINGS.TASK_CATALOGS.REQUIRES_NOTE') }}
        </label>
        <label class="flex items-center gap-3 text-sm text-n-slate-12">
          <Switch v-model="outcomeForm.active" />
          {{ t('CRM.SETTINGS.TASK_CATALOGS.ACTIVE') }}
        </label>
      </div>
    </Dialog>
  </section>
</template>
