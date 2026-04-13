<script setup>
import { computed, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import PersonalCampaignEmptyState from 'dashboard/components-next/Campaigns/EmptyState/PersonalCampaignEmptyState.vue';
import OutboundWorkspaceLayout from 'dashboard/components-next/Outbound/OutboundWorkspaceLayout.vue';
import TouchEditorDrawer from 'dashboard/components-next/Outbound/TouchEditorDrawer.vue';
import TouchList from 'dashboard/components-next/Outbound/TouchList.vue';
import TouchesAPI from 'dashboard/api/touches';

const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const touches = ref([]);
const isFetchingTouches = ref(false);
const isTouchEditorOpen = ref(false);
const editingTouch = ref(null);
const mutatingTouchId = ref(null);

const entityKindLabelFromType = type => {
  switch (type) {
    case 'Crm::Deal':
    case 'deal':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.DEAL');
    case 'Crm::Task':
    case 'task':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.TASK');
    case 'Scheduling::Appointment':
    case 'appointment':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.APPOINTMENT');
    case 'Conversation':
    case 'conversation':
    default:
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.CONVERSATION');
  }
};

const formatStatus = status => {
  switch (status) {
    case 'pending':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.PENDING');
    case 'processing':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.PROCESSING');
    case 'completed':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.COMPLETED');
    case 'cancelled':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.CANCELLED');
    case 'failed':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.FAILED');
    case 'draft':
    default:
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.DRAFT');
  }
};

const entityContext = computed(() => {
  const remindableType = route.query.remindable_type?.toString() || '';
  const remindableId = route.query.remindable_id?.toString() || '';
  const conversationId = route.query.conversation_id?.toString() || '';

  return {
    conversationId,
    remindableId,
    remindableType,
  };
});

const hasEntityContext = computed(() => {
  return !!(
    entityContext.value.remindableType && entityContext.value.remindableId
  );
});

const entityScopeLabel = computed(() => {
  if (!hasEntityContext.value) return '';

  return `${entityKindLabelFromType(entityContext.value.remindableType)} #${entityContext.value.remindableId}`;
});

const touchEditorSelectionMode = computed(() => {
  if (hasEntityContext.value || editingTouch.value?.remindable?.id) {
    return 'entity';
  }

  return 'target';
});

const activeStatusFilter = computed(
  () => route.query.status?.toString() || 'all'
);

const statusFilterOptions = computed(() => {
  return [
    'all',
    'draft',
    'pending',
    'processing',
    'completed',
    'cancelled',
    'failed',
  ].map(status => ({
    id: status,
    label:
      status === 'all'
        ? t('OUTBOUND_WORKSPACE.TOUCHES.FILTERS.ALL_STATUSES')
        : formatStatus(status),
  }));
});

const sortedTouches = computed(() => {
  return [...touches.value].sort((left, right) => {
    const leftTime = new Date(
      left.updated_at || left.created_at || 0
    ).getTime();
    const rightTime = new Date(
      right.updated_at || right.created_at || 0
    ).getTime();

    return rightTime - leftTime;
  });
});

const fetchTouches = async () => {
  isFetchingTouches.value = true;

  try {
    const params = {};

    if (entityContext.value.remindableType) {
      params.remindable_type = entityContext.value.remindableType;
    }

    if (entityContext.value.remindableId) {
      params.remindable_id = entityContext.value.remindableId;
    }

    if (entityContext.value.conversationId) {
      params.conversation_id = entityContext.value.conversationId;
    }

    if (activeStatusFilter.value !== 'all') {
      params.status = activeStatusFilter.value;
    }

    const { data } = await TouchesAPI.get(params);
    touches.value = data.payload || [];
  } catch (error) {
    useAlert(
      error?.message || t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.LOAD_TOUCHES')
    );
  } finally {
    isFetchingTouches.value = false;
  }
};

const refreshTouches = async () => {
  await fetchTouches();
};

const approveTouch = async touch => {
  mutatingTouchId.value = touch.id;

  try {
    await TouchesAPI.approve(touch.id);
    await fetchTouches();
    useAlert(t('OUTBOUND_WORKSPACE.TOUCHES.ALL.APPROVE_SUCCESS'));
  } catch (error) {
    useAlert(
      error?.message || t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.APPROVE_TOUCH')
    );
  } finally {
    mutatingTouchId.value = null;
  }
};

const cancelTouch = async touch => {
  mutatingTouchId.value = touch.id;

  try {
    await TouchesAPI.cancel(touch.id);
    await fetchTouches();
    useAlert(t('OUTBOUND_WORKSPACE.TOUCHES.ALL.CANCEL_SUCCESS'));
  } catch (error) {
    useAlert(
      error?.message || t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.CANCEL_TOUCH')
    );
  } finally {
    mutatingTouchId.value = null;
  }
};

const openCreateTouch = () => {
  editingTouch.value = null;
  isTouchEditorOpen.value = true;
};

const openEditTouch = touch => {
  editingTouch.value = touch;
  isTouchEditorOpen.value = true;
};

const closeTouchEditor = () => {
  isTouchEditorOpen.value = false;
  editingTouch.value = null;
};

const handleTouchSaved = async () => {
  await fetchTouches();
};

const setStatusFilter = status => {
  router.replace({
    query: {
      ...route.query,
      status: status === 'all' ? undefined : status,
    },
  });
};

const openPlansPage = () => {
  router.push({
    name: 'outbound_touch_plans_index',
    params: route.params,
    query: {
      ...(entityContext.value.conversationId
        ? { conversation_id: entityContext.value.conversationId }
        : {}),
      ...(entityContext.value.remindableId
        ? { remindable_id: entityContext.value.remindableId }
        : {}),
      ...(entityContext.value.remindableType
        ? { remindable_type: entityContext.value.remindableType }
        : {}),
    },
  });
};

watch(
  () => [
    activeStatusFilter.value,
    entityContext.value.conversationId,
    entityContext.value.remindableId,
    entityContext.value.remindableType,
  ],
  () => {
    fetchTouches();
  },
  { immediate: true }
);
</script>

<template>
  <OutboundWorkspaceLayout
    :title="$t('OUTBOUND_WORKSPACE.TOUCHES.TITLE')"
    :description="$t('OUTBOUND_WORKSPACE.TOUCHES.DESCRIPTION')"
  >
    <template #meta>
      <span class="text-sm text-n-slate-11">
        {{
          $t('OUTBOUND_WORKSPACE.TOUCHES.COUNT', {
            n: sortedTouches.length,
          })
        }}
      </span>
      <span
        v-if="hasEntityContext"
        class="inline-flex rounded-full bg-n-brand/10 px-3 py-1 text-xs font-medium text-n-brand"
      >
        {{
          $t('OUTBOUND_WORKSPACE.TOUCHES.HERO.SCOPED_BADGE', {
            entity: entityScopeLabel,
          })
        }}
      </span>
    </template>

    <template #actions>
      <Button
        size="sm"
        :label="$t('OUTBOUND_WORKSPACE.TOUCHES.ACTIONS.CREATE')"
        @click="openCreateTouch"
      />
      <Button
        size="sm"
        slate
        :label="$t('SIDEBAR.TOUCH_PLANS')"
        @click="openPlansPage"
      />
      <Button
        size="sm"
        slate
        :label="$t('OUTBOUND_WORKSPACE.TOUCHES.REFRESH')"
        @click="refreshTouches"
      />
    </template>

    <div class="mb-4 flex flex-wrap items-center gap-2">
      <button
        v-for="filter in statusFilterOptions"
        :key="filter.id"
        type="button"
        class="inline-flex items-center rounded-full px-3 py-1.5 text-sm font-medium transition-colors"
        :class="
          activeStatusFilter === filter.id
            ? 'bg-n-brand text-white'
            : 'bg-n-solid-2 text-n-slate-11 outline outline-1 outline-n-container hover:bg-n-alpha-2'
        "
        @click="setStatusFilter(filter.id)"
      >
        {{ filter.label }}
      </button>
    </div>

    <div
      v-if="isFetchingTouches"
      class="flex items-center justify-center py-10 text-n-slate-11"
    >
      <Spinner />
    </div>

    <TouchList
      v-else-if="sortedTouches.length"
      :touches="sortedTouches"
      :mutating-touch-id="mutatingTouchId"
      @edit="openEditTouch"
      @approve="approveTouch"
      @cancel="cancelTouch"
    />
    <PersonalCampaignEmptyState
      v-else
      :title="$t('OUTBOUND_WORKSPACE.TOUCHES.EMPTY_TITLE')"
      :subtitle="$t('OUTBOUND_WORKSPACE.TOUCHES.EMPTY_SUBTITLE')"
      class="pt-8"
    />
  </OutboundWorkspaceLayout>

  <TouchEditorDrawer
    v-model="isTouchEditorOpen"
    :conversation-id="
      editingTouch?.conversation_id || entityContext.conversationId
    "
    :remindable-id="editingTouch?.remindable?.id || entityContext.remindableId"
    :remindable-type="
      editingTouch?.remindable?.type || entityContext.remindableType
    "
    :selection-mode="touchEditorSelectionMode"
    :create-label="$t('OUTBOUND_WORKSPACE.TOUCHES.EDITOR.CREATE_TITLE')"
    :create-title="$t('OUTBOUND_WORKSPACE.TOUCHES.EDITOR.CREATE_TITLE')"
    :edit-title="$t('OUTBOUND_WORKSPACE.TOUCHES.EDITOR.EDIT_TITLE')"
    :save-label="$t('OUTBOUND_WORKSPACE.TOUCHES.EDITOR.SAVE')"
    :success-created-message="
      $t('OUTBOUND_WORKSPACE.TOUCHES.EDITOR.SUCCESS_CREATED')
    "
    :success-updated-message="
      $t('OUTBOUND_WORKSPACE.TOUCHES.EDITOR.SUCCESS_UPDATED')
    "
    :touch="editingTouch"
    @close="closeTouchEditor"
    @saved="handleTouchSaved"
  />
</template>
