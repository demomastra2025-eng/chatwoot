<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { format } from 'date-fns';
import { useI18n } from 'vue-i18n';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import CrmTasksAPI from 'dashboard/api/crm/tasks';
import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import { isCommunicationThread } from 'dashboard/helper/communicationThreadHelper';
import CrmTaskFormFields from 'dashboard/components-next/CRM/CrmTaskFormFields.vue';
import {
  taskStatusLabel,
  taskTypeLabel,
} from 'dashboard/components-next/CRM/taskCatalogLabels';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import { buildDefaultCustomAttributes } from 'dashboard/stores/crm/customFieldDefaults';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import {
  formatCrmErrorMessage,
  normalizePayload,
} from 'dashboard/stores/crm/shared';

const props = defineProps({
  modelValue: { type: Boolean, default: false },
  contact: { type: Object, required: true },
  currentChat: { type: Object, required: true },
});
const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();
const referencesStore = useCrmReferencesStore();
const agents = useMapGetter('agents/getAgents');
const currentUser = useMapGetter('getCurrentUser');
const currentAccountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledOnAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);
const saving = ref(false);
const loading = ref(false);
const dealOptions = ref([]);
const form = reactive({
  activityType: 'task',
  allDay: false,
  assigneeId: '',
  contextKind: 'personal',
  customAttributes: {},
  dealId: '',
  description: '',
  dueAt: '',
  originatingCommunicationThreadId: '',
  originatingConversationDisplayId: '',
  originatingConversationId: '',
  priority: 'medium',
  startAt: '',
  statusId: '',
  title: '',
});
const open = computed({
  get: () => props.modelValue,
  set: value => emit('update:modelValue', value),
});
const isThread = computed(() => isCommunicationThread(props.currentChat));
const conversationDisplayId = computed(() => {
  const chat = props.currentChat;
  if (chat?.is_draft) return null;
  const replyConversationId =
    Number(
      chat?.active_reply_channel?.conversation_id ||
        chat?.active_reply_channel_conversation_id ||
        chat?.conversation_ids?.[0]
    ) || null;
  if (replyConversationId) return replyConversationId;
  if (isThread.value) return null;
  return Number(chat?.display_id || chat?.displayId || chat?.id) || null;
});
const communicationThreadId = computed(() => {
  const chat = props.currentChat;
  if (chat?.is_draft || !isThread.value) return null;
  return Number(chat?.display_id || chat?.displayId || chat?.id) || null;
});
const canLoadDeals = computed(() => {
  if (
    typeof isFeatureEnabledOnAccount.value === 'function' &&
    Number(currentAccountId.value) > 0
  ) {
    return Boolean(
      isFeatureEnabledOnAccount.value(currentAccountId.value, 'crm_deals')
    );
  }
  return true;
});
const assigneeOptions = computed(() =>
  (agents.value || []).map(agent => ({
    label: agent.name || agent.email,
    value: agent.id,
  }))
);
const taskPriorityOptions = computed(() =>
  ['low', 'medium', 'high', 'urgent'].map(value => ({
    label: t(`CRM.TASKS.PRIORITY.${value}`),
    value,
  }))
);
const taskStatusOptions = computed(() =>
  referencesStore.taskStatuses
    .filter(status => status.active !== false)
    .map(status => ({
      label: taskStatusLabel(status, t),
      value: status.id,
    }))
);
const taskContextOptions = computed(() =>
  ['personal', 'sales'].map(value => ({
    label: t(`CRM.TASKS.CONTEXT_KIND.${value}`),
    value,
  }))
);
const activityTypeOptions = computed(() => {
  const types = referencesStore.taskTypes.filter(type => type.active !== false);
  if (!types.length)
    return [{ label: t('CRM.TASKS.ACTIVITY_TYPE.task'), value: 'task' }];
  return types.map(type => ({
    label: taskTypeLabel(type, t),
    value: type.code,
  }));
});
const applicableTaskFieldDefinitions = computed(() =>
  referencesStore.taskFieldDefinitions.filter(definition => {
    const contexts = definition.rules?.contexts || [];
    const kind = form.contextKind === 'sales' ? 'deal_task' : 'standalone_task';
    return !contexts.length || contexts.includes(kind);
  })
);
const updateFormActivityType = value => {
  form.activityType = value;
};
const updateAllDay = enabled => {
  form.allDay = enabled;
  if (enabled) {
    form.dueAt = format(
      form.dueAt ? new Date(form.dueAt) : new Date(),
      'yyyy-MM-dd'
    );
    form.startAt = '';
  } else {
    form.dueAt = '';
  }
};
const loadDealOptions = async () => {
  if (!canLoadDeals.value) return [];
  try {
    const dealsResponse = await CrmDealsAPI.get({
      archived: false,
      page: 1,
      per_page: 100,
    });
    return normalizePayload(dealsResponse.data).map(deal => ({
      label: deal.title,
      value: deal.id,
    }));
  } catch (error) {
    if (error?.response?.status === 403) return [];
    throw error;
  }
};
const resetForm = () => {
  const defaultStatus = referencesStore.taskStatuses.find(
    status => status.default && status.active !== false
  );
  const defaultType =
    referencesStore.taskTypes.find(type => type.default && type.active) ||
    referencesStore.taskTypes.find(type => type.active);
  const dealId = canLoadDeals.value
    ? props.currentChat.crm_deal_id || props.currentChat.deal_id || ''
    : '';
  Object.assign(form, {
    activityType: defaultType?.code || 'task',
    allDay: false,
    assigneeId: currentUser.value?.id || '',
    contextKind: dealId ? 'sales' : 'personal',
    customAttributes: buildDefaultCustomAttributes(
      referencesStore.taskFieldDefinitions.filter(definition => {
        const contexts = definition.rules?.contexts || [];
        return (
          !contexts.length ||
          contexts.includes(dealId ? 'deal_task' : 'standalone_task')
        );
      })
    ),
    dealId,
    description: '',
    dueAt: '',
    originatingCommunicationThreadId: communicationThreadId.value || '',
    originatingConversationDisplayId: conversationDisplayId.value || '',
    originatingConversationId: conversationDisplayId.value || '',
    priority: 'medium',
    startAt: '',
    statusId: defaultStatus?.id || '',
    title: props.contact.name
      ? t('CRM.TASKS.PREFILL.CONVERSATION_WITH_CONTACT', {
          contactName: props.contact.name,
        })
      : '',
  });
};
watch(
  () => props.modelValue,
  async visible => {
    if (!visible) return;
    resetForm();
    loading.value = true;
    try {
      const [, , , loadedDeals] = await Promise.all([
        referencesStore.loadTaskStatuses(),
        referencesStore.loadTaskTypes(),
        referencesStore.loadFieldDefinitions('task'),
        loadDealOptions(),
      ]);
      if (!props.modelValue) return;
      dealOptions.value = loadedDeals;
      resetForm();
    } catch (error) {
      useAlert(formatCrmErrorMessage(error, t));
    } finally {
      loading.value = false;
    }
  },
  { immediate: true }
);
const save = async () => {
  if (
    saving.value ||
    loading.value ||
    !form.title.trim() ||
    (form.contextKind === 'sales' && !form.dealId)
  )
    return;
  saving.value = true;
  try {
    const type = referencesStore.taskTypes.find(
      item => item.code === form.activityType
    );
    await CrmTasksAPI.create({
      title: form.title.trim(),
      description: form.description || undefined,
      activity_type: form.activityType,
      task_type_id: type?.id || undefined,
      context_kind: form.contextKind,
      custom_attributes: form.customAttributes,
      deal_id: form.dealId ? Number(form.dealId) : undefined,
      originating_conversation_display_id: form.originatingConversationDisplayId
        ? Number(form.originatingConversationDisplayId)
        : undefined,
      originating_conversation_id: form.originatingConversationId
        ? Number(form.originatingConversationId)
        : undefined,
      originating_communication_thread_id: form.originatingCommunicationThreadId
        ? Number(form.originatingCommunicationThreadId)
        : undefined,
      assignee_id: form.assigneeId ? Number(form.assigneeId) : undefined,
      priority: form.priority,
      status_id: form.statusId ? Number(form.statusId) : undefined,
      all_day: form.allDay,
      due_on: form.allDay ? form.dueAt || undefined : undefined,
      start_at: form.allDay ? undefined : form.startAt || undefined,
      due_at: form.allDay ? undefined : form.dueAt || undefined,
    });
    open.value = false;
    useAlert(t('CRM.TASKS.SUCCESS_CREATED'));
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  } finally {
    saving.value = false;
  }
};
</script>

<template>
  <SchedulingDrawer
    v-model="open"
    width="sm"
    :title="t('CRM.TASKS.CREATE_TITLE')"
    :description="t('CRM.TASKS.DRAWER_DESCRIPTION')"
    :confirm-label="t('CRM.GENERAL.CREATE')"
    :is-loading="saving || loading"
    :disable-confirm="
      loading ||
      !form.title.trim() ||
      (form.contextKind === 'sales' && !form.dealId)
    "
    @confirm="save"
  >
    <CrmTaskFormFields
      :form="form"
      :activity-type-options="activityTypeOptions"
      :assignee-options="assigneeOptions"
      :task-priority-options="taskPriorityOptions"
      :task-status-options="taskStatusOptions"
      :task-context-options="taskContextOptions"
      :deal-options="dealOptions"
      :applicable-task-field-definitions="applicableTaskFieldDefinitions"
      :update-form-activity-type="updateFormActivityType"
      :update-all-day="updateAllDay"
      @update:field="(field, value) => (form[field] = value)"
    />
  </SchedulingDrawer>
</template>
