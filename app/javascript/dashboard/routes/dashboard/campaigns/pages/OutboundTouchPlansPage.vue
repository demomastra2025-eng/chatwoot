<script setup>
import { computed, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';

import TouchPlansAPI from 'dashboard/api/touchPlans';
import TouchesAPI from 'dashboard/api/touches';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import EmptyStateLayout from 'dashboard/components-next/EmptyStateLayout.vue';
import OutboundWorkspaceLayout from 'dashboard/components-next/Outbound/OutboundWorkspaceLayout.vue';
import TouchPlanEditorDrawer from 'dashboard/components-next/Outbound/TouchPlanEditorDrawer.vue';
import TouchPlanList from 'dashboard/components-next/Outbound/TouchPlanList.vue';

const route = useRoute();
const { t } = useI18n();

const touchPlans = ref([]);
const isFetchingTouchPlans = ref(false);
const isTouchPlanEditorOpen = ref(false);
const editingTouchPlan = ref(null);
const mutatingPlanId = ref(null);

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

const entityContextLabel = computed(() => {
  if (!hasEntityContext.value) return '';

  const typeKey = entityContext.value.remindableType
    .replace(/^Crm::/, '')
    .replace(/^Scheduling::/, '')
    .replace('Conversation', 'CONVERSATION')
    .replace('Deal', 'DEAL')
    .replace('Task', 'TASK')
    .replace('Appointment', 'APPOINTMENT')
    .toUpperCase();

  return `${t(`OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.${typeKey}`)} #${entityContext.value.remindableId}`;
});

const sortedPlans = computed(() => {
  return [...touchPlans.value].sort((left, right) => {
    if (left.archived !== right.archived) {
      return left.archived ? 1 : -1;
    }

    const leftTime = new Date(
      left.updated_at || left.created_at || 0
    ).getTime();
    const rightTime = new Date(
      right.updated_at || right.created_at || 0
    ).getTime();

    return rightTime - leftTime;
  });
});

const fetchTouchPlans = async () => {
  isFetchingTouchPlans.value = true;

  try {
    const { data } = await TouchPlansAPI.get();
    touchPlans.value = data.payload || [];
  } catch (error) {
    useAlert(
      error?.message || t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.LOAD_PLANS')
    );
  } finally {
    isFetchingTouchPlans.value = false;
  }
};

const openCreateTouchPlan = () => {
  editingTouchPlan.value = null;
  isTouchPlanEditorOpen.value = true;
};

const openEditTouchPlan = touchPlan => {
  editingTouchPlan.value = touchPlan;
  isTouchPlanEditorOpen.value = true;
};

const closeTouchPlanEditor = () => {
  isTouchPlanEditorOpen.value = false;
  editingTouchPlan.value = null;
};

const handleTouchPlanSaved = async () => {
  await fetchTouchPlans();
};

const archiveTouchPlan = async touchPlan => {
  mutatingPlanId.value = touchPlan.id;

  try {
    await TouchPlansAPI.archive(touchPlan.id);
    await fetchTouchPlans();
    useAlert(t('OUTBOUND_WORKSPACE.TOUCHES.PLANS.ARCHIVE_SUCCESS'));
  } catch (error) {
    useAlert(
      error?.message || t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.ARCHIVE_PLAN')
    );
  } finally {
    mutatingPlanId.value = null;
  }
};

const applyTouchPlan = async touchPlan => {
  if (!hasEntityContext.value) {
    useAlert(
      t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.APPLY_PLAN_REQUIRES_CONTEXT')
    );
    return;
  }

  mutatingPlanId.value = touchPlan.id;

  try {
    await TouchPlansAPI.apply(touchPlan.id, {
      remindable_id: entityContext.value.remindableId,
      remindable_type: entityContext.value.remindableType,
    });

    if (
      entityContext.value.remindableId &&
      entityContext.value.remindableType
    ) {
      await TouchesAPI.get({
        remindable_id: entityContext.value.remindableId,
        remindable_type: entityContext.value.remindableType,
        ...(entityContext.value.conversationId
          ? { conversation_id: entityContext.value.conversationId }
          : {}),
      });
    }

    useAlert(t('OUTBOUND_WORKSPACE.TOUCHES.PLANS.APPLY_SUCCESS'));
  } catch (error) {
    useAlert(
      error?.message || t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.APPLY_PLAN')
    );
  } finally {
    mutatingPlanId.value = null;
  }
};

watch(
  () => route.fullPath,
  () => {
    fetchTouchPlans();
  },
  { immediate: true }
);
</script>

<template>
  <OutboundWorkspaceLayout
    :title="$t('OUTBOUND_WORKSPACE.TOUCH_PLANS.TITLE')"
    :description="$t('OUTBOUND_WORKSPACE.TOUCH_PLANS.DESCRIPTION')"
  >
    <template #meta>
      <span class="text-sm text-n-slate-11">
        {{
          $t('OUTBOUND_WORKSPACE.TOUCH_PLANS.COUNT', {
            n: sortedPlans.length,
          })
        }}
      </span>
      <span
        v-if="hasEntityContext"
        class="inline-flex rounded-full bg-n-brand/10 px-3 py-1 text-xs font-medium text-n-brand"
      >
        {{
          $t('OUTBOUND_WORKSPACE.TOUCH_PLANS.CONTEXT_BADGE', {
            entity: entityContextLabel,
          })
        }}
      </span>
    </template>

    <template #actions>
      <Button
        size="sm"
        :label="$t('OUTBOUND_WORKSPACE.TOUCH_PLANS.ACTIONS.CREATE')"
        @click="openCreateTouchPlan"
      />
      <Button
        size="sm"
        slate
        :label="$t('OUTBOUND_WORKSPACE.TOUCH_PLANS.ACTIONS.REFRESH')"
        @click="fetchTouchPlans"
      />
    </template>

    <div
      v-if="isFetchingTouchPlans"
      class="flex items-center justify-center py-10 text-n-slate-11"
    >
      <Spinner />
    </div>

    <TouchPlanList
      v-else-if="sortedPlans.length"
      :touch-plans="sortedPlans"
      :mutating-plan-id="mutatingPlanId"
      :has-entity-context="hasEntityContext"
      @edit="openEditTouchPlan"
      @apply="applyTouchPlan"
      @archive="archiveTouchPlan"
    />
    <EmptyStateLayout
      v-else
      :title="$t('OUTBOUND_WORKSPACE.TOUCH_PLANS.EMPTY_TITLE')"
      :subtitle="$t('OUTBOUND_WORKSPACE.TOUCH_PLANS.EMPTY_SUBTITLE')"
      :show-backdrop="false"
      class="pt-8"
    >
      <template #actions>
        <Button
          size="sm"
          :label="$t('OUTBOUND_WORKSPACE.TOUCH_PLANS.ACTIONS.CREATE')"
          @click="openCreateTouchPlan"
        />
      </template>
    </EmptyStateLayout>
  </OutboundWorkspaceLayout>

  <TouchPlanEditorDrawer
    v-model="isTouchPlanEditorOpen"
    :touch-plan="editingTouchPlan"
    :create-title="$t('OUTBOUND_WORKSPACE.TOUCHES.PLANS_MODAL.CREATE_TITLE')"
    :edit-title="$t('OUTBOUND_WORKSPACE.TOUCHES.PLANS_MODAL.EDIT_TITLE')"
    :description="
      $t('OUTBOUND_WORKSPACE.TOUCHES.PLANS_MODAL.EDITOR_DESCRIPTION')
    "
    :create-label="$t('OUTBOUND_WORKSPACE.TOUCHES.PLANS_MODAL.CREATE')"
    :save-label="$t('OUTBOUND_WORKSPACE.TOUCHES.PLANS_MODAL.SAVE')"
    @close="closeTouchPlanEditor"
    @saved="handleTouchPlanSaved"
  />
</template>
