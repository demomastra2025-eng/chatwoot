<script setup>
import { ref, computed, onMounted, onUnmounted, useAttrs, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { getUnixTime } from 'date-fns';
import { findSnoozeTime } from 'dashboard/helper/snoozeHelpers';
import { emitter } from 'shared/helpers/mitt';
import { useMapGetter } from 'dashboard/composables/store';
import wootConstants from 'dashboard/constants/globals';
import {
  CMD_BULK_ACTION_SNOOZE_CONVERSATION,
  CMD_BULK_ACTION_REOPEN_CONVERSATION,
  CMD_BULK_ACTION_RESOLVE_CONVERSATION,
} from 'dashboard/helper/commandbar/events';

import NextButton from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import BulkAgentActions from './BulkAgentActions.vue';
import BulkUpdateActions from './BulkUpdateActions.vue';
import BulkLabelActions from './BulkLabelActions.vue';
import BulkTeamActions from './BulkTeamActions.vue';
import CustomSnoozeModal from 'dashboard/components/CustomSnoozeModal.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import ConversationStatusReasonDialog from 'dashboard/components-next/ConversationWorkflow/ConversationStatusReasonDialog.vue';

const props = defineProps({
  selectedCount: {
    type: Number,
    default: 0,
  },
  selectionVersion: {
    type: Number,
    default: 0,
  },
  selectionContextKey: {
    type: String,
    default: '',
  },
  selectableConversationsCount: {
    type: Number,
    default: 0,
  },
  canSelectAllMatching: {
    type: Boolean,
    default: false,
  },
  isSearchCapped: {
    type: Boolean,
    default: false,
  },
  isSelectingAll: {
    type: Boolean,
    default: false,
  },
  allConversationsSelected: {
    type: Boolean,
    default: false,
  },
  selectedInboxes: {
    type: Array,
    default: () => [],
  },
  showOpenAction: {
    type: Boolean,
    default: false,
  },
  showResolvedAction: {
    type: Boolean,
    default: false,
  },
  showSnoozedAction: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits([
  'selectAllConversations',
  'selectAllMatching',
  'assignAgent',
  'assignLabels',
  'assignTeam',
  'updateConversations',
  'markRead',
]);

defineOptions({
  inheritAttrs: false,
});

const attrs = useAttrs();
const { t } = useI18n();

const bulkActionRun = useMapGetter('bulkActions/getCurrentBulkActionRun');
const bulkActionUiFlags = useMapGetter('bulkActions/getUIFlags');
const showCustomTimeSnoozeModal = ref(false);
const statusReasonDialogRef = ref(null);
const closeConfirmationDialogRef = ref(null);
const closeConfirmationResolver = ref(null);

const allSelected = computed({
  get: () => props.allConversationsSelected,
  set: value => {
    if (bulkActionUiFlags.value.isUpdating) return;
    emit('selectAllConversations', value);
  },
});

const progressPercentage = computed(
  () => bulkActionRun.value?.progress_percentage || 0
);

const progressLabel = computed(() => {
  if (!bulkActionRun.value) return '';

  const actionLabels = {
    add_labels: t('BULK_ACTION.PROGRESS.ACTIONS.add_labels'),
    remove_labels: t('BULK_ACTION.PROGRESS.ACTIONS.remove_labels'),
    assign_agent: t('BULK_ACTION.PROGRESS.ACTIONS.assign_agent'),
    assign_team: t('BULK_ACTION.PROGRESS.ACTIONS.assign_team'),
    update_status: t('BULK_ACTION.PROGRESS.ACTIONS.update_status'),
    mark_read: t('BULK_ACTION.PROGRESS.ACTIONS.mark_read'),
  };
  const actionName = bulkActionRun.value.action_name;
  const actionLabel =
    actionLabels[actionName] || t('BULK_ACTION.PROGRESS.ACTIONS.update');

  return t('BULK_ACTION.PROGRESS.TITLE', {
    action: actionLabel,
    processedCount: bulkActionRun.value.processed_count || 0,
    totalCount: bulkActionRun.value.total_count || 0,
  });
});

const progressMetaLabel = computed(() => {
  const labels = [];
  if (bulkActionRun.value?.failed_count) {
    labels.push(
      t('BULK_ACTION.PROGRESS.FAILED', {
        count: bulkActionRun.value.failed_count,
      })
    );
  }
  if (bulkActionRun.value?.skipped_count) {
    labels.push(
      t('BULK_ACTION.PROGRESS.SKIPPED', {
        count: bulkActionRun.value.skipped_count,
      })
    );
  }
  return labels.join(' · ');
});

function confirmCloseSelection() {
  return new Promise(resolve => {
    closeConfirmationResolver.value = resolve;
    closeConfirmationDialogRef.value?.open();
  });
}

function resolveCloseConfirmation(confirmed) {
  const resolver = closeConfirmationResolver.value;
  closeConfirmationResolver.value = null;
  resolver?.(confirmed);
}

function confirmClose() {
  resolveCloseConfirmation(true);
  closeConfirmationDialogRef.value?.close();
}

function cancelClose() {
  resolveCloseConfirmation(false);
}

async function resolveStatusReason(status) {
  const result = await statusReasonDialogRef.value?.open({ status });
  if (result === statusReasonDialogRef.value?.CANCELLED) {
    return { cancelled: true };
  }

  return { statusReason: result };
}

async function updateConversations(status, snoozedUntil = null) {
  if (bulkActionUiFlags.value.isUpdating) return;
  const versionAtStart = props.selectionVersion;
  const contextAtStart = props.selectionContextKey;

  if (status === wootConstants.STATUS_TYPE.RESOLVED) {
    const confirmed = await confirmCloseSelection();
    if (
      !confirmed ||
      versionAtStart !== props.selectionVersion ||
      contextAtStart !== props.selectionContextKey
    ) {
      return;
    }
  }

  const { cancelled, statusReason } = await resolveStatusReason(status);
  if (
    cancelled ||
    versionAtStart !== props.selectionVersion ||
    contextAtStart !== props.selectionContextKey
  ) {
    return;
  }

  emit('updateConversations', status, snoozedUntil, statusReason);
}

watch(
  () => [props.selectionVersion, props.selectionContextKey],
  () => {
    resolveCloseConfirmation(false);
    closeConfirmationDialogRef.value?.close();
    statusReasonDialogRef.value?.cancel();
  }
);

function assignAgent(agent) {
  if (bulkActionUiFlags.value.isUpdating) return;
  emit('assignAgent', agent);
}

function assignLabels(labels) {
  if (bulkActionUiFlags.value.isUpdating) return;
  emit('assignLabels', labels);
}

function assignTeam(team) {
  if (bulkActionUiFlags.value.isUpdating) return;
  emit('assignTeam', team);
}

function markRead() {
  if (bulkActionUiFlags.value.isUpdating) return;
  emit('markRead');
}

function onCmdSnoozeConversation(snoozeType) {
  if (snoozeType === wootConstants.SNOOZE_OPTIONS.UNTIL_CUSTOM_TIME) {
    showCustomTimeSnoozeModal.value = true;
  } else if (typeof snoozeType === 'number') {
    updateConversations('snoozed', snoozeType);
  } else {
    updateConversations('snoozed', findSnoozeTime(snoozeType) || null);
  }
}

function onCmdReopenConversation() {
  updateConversations('open', null);
}

function onCmdResolveConversation() {
  updateConversations('resolved', null);
}

function customSnoozeTime(customSnoozedTime) {
  showCustomTimeSnoozeModal.value = false;
  if (customSnoozedTime) {
    updateConversations('snoozed', getUnixTime(customSnoozedTime));
  }
}

function hideCustomSnoozeModal() {
  showCustomTimeSnoozeModal.value = false;
}

onMounted(() => {
  emitter.on(CMD_BULK_ACTION_SNOOZE_CONVERSATION, onCmdSnoozeConversation);
  emitter.on(CMD_BULK_ACTION_REOPEN_CONVERSATION, onCmdReopenConversation);
  emitter.on(CMD_BULK_ACTION_RESOLVE_CONVERSATION, onCmdResolveConversation);
});

onUnmounted(() => {
  resolveCloseConfirmation(false);
  statusReasonDialogRef.value?.cancel();
  emitter.off(CMD_BULK_ACTION_SNOOZE_CONVERSATION, onCmdSnoozeConversation);
  emitter.off(CMD_BULK_ACTION_REOPEN_CONVERSATION, onCmdReopenConversation);
  emitter.off(CMD_BULK_ACTION_RESOLVE_CONVERSATION, onCmdResolveConversation);
});
</script>

<template>
  <Transition
    enter-active-class="transition-all duration-200 ease-out origin-top"
    enter-from-class="opacity-0 scale-95 -translate-y-2"
    enter-to-class="opacity-100 scale-100 translate-y-0"
    leave-active-class="transition-all duration-150 ease-in origin-top"
    leave-from-class="opacity-100 scale-100 translate-y-0"
    leave-to-class="opacity-0 scale-95 -translate-y-2"
  >
    <!-- The panel sits in the list flow above the conversations so it never
         covers the last cards or the list footer. -->
    <div
      v-if="selectedCount > 0"
      v-bind="attrs"
      data-test-id="conversation-bulk-actions-panel"
      class="relative z-30 w-full min-w-0 max-w-full shrink-0 origin-top px-3 pb-2"
    >
      <div class="min-w-0 max-w-full">
        <div
          class="flex min-w-0 max-w-full flex-col gap-1.5 p-2 bg-n-button-color outline outline-1 -outline-offset-1 rounded-[10px] outline-n-weak shadow-[0_0_12px_0_rgba(27,40,59,0.08)]"
        >
          <div
            data-test-id="bulk-selection-row"
            class="flex min-w-0 items-center justify-between gap-2"
          >
            <label class="flex min-w-0 cursor-pointer items-center gap-1.5">
              <Checkbox
                v-model="allSelected"
                :indeterminate="!allConversationsSelected"
                :disabled="bulkActionUiFlags.isUpdating"
              />
              <span class="min-w-0 cursor-pointer text-sm text-n-slate-12">
                {{
                  $t('BULK_ACTION.CONVERSATIONS_SELECTED', {
                    conversationCount: selectedCount,
                  })
                }}
              </span>
            </label>
            <NextButton
              ghost
              sm
              class="shrink-0 !h-6 !px-1 !text-n-blue-11"
              :disabled="bulkActionUiFlags.isUpdating"
              @click="allSelected = false"
            >
              {{ $t('BULK_ACTION.CLEAR_SELECTION') }}
            </NextButton>
          </div>
          <div
            v-if="canSelectAllMatching"
            data-test-id="bulk-select-matching-row"
            class="min-w-0 max-w-full"
          >
            <NextButton
              link
              sm
              start
              class="max-w-full !text-start !text-n-blue-11"
              :disabled="bulkActionUiFlags.isUpdating || isSelectingAll"
              :is-loading="isSelectingAll"
              @click="emit('selectAllMatching')"
            >
              <span class="min-w-0 whitespace-normal break-words text-start">
                {{
                  $t('BULK_ACTION.SELECT_ALL_MATCHING', {
                    count: selectableConversationsCount,
                  })
                }}
              </span>
            </NextButton>
          </div>
          <div
            data-test-id="bulk-action-buttons-row"
            class="flex min-w-0 max-w-full flex-wrap items-center justify-between gap-2"
          >
            <BulkLabelActions
              :disabled="bulkActionUiFlags.isUpdating"
              @assign="assignLabels"
            />
            <NextButton
              v-tooltip="$t('BULK_ACTION.MARK_READ.TOOLTIP')"
              icon="i-lucide-mail-open"
              slate
              xs
              ghost
              :disabled="bulkActionUiFlags.isUpdating"
              @click="markRead"
            />
            <BulkUpdateActions
              :show-resolve="!showResolvedAction"
              :show-reopen="!showOpenAction"
              :show-snooze="!showSnoozedAction"
              :disabled="bulkActionUiFlags.isUpdating"
              @update="updateConversations"
            />
            <BulkAgentActions
              :selected-inboxes="selectedInboxes"
              :conversation-count="selectedCount"
              :disabled="bulkActionUiFlags.isUpdating"
              @select="assignAgent"
            />
            <BulkTeamActions
              :conversation-count="selectedCount"
              :disabled="bulkActionUiFlags.isUpdating"
              @select="assignTeam"
            />
          </div>
        </div>
        <div
          v-if="bulkActionUiFlags.isUpdating && bulkActionRun"
          class="mt-2 rounded-lg border border-solid border-n-weak bg-n-alpha-2 px-2.5 py-2"
        >
          <div class="flex items-center justify-between gap-3">
            <span class="text-xs font-medium text-n-slate-12">
              {{ progressLabel }}
            </span>
            <span
              v-if="progressMetaLabel"
              class="text-[11px] text-n-slate-10 tabular-nums"
            >
              {{ progressMetaLabel }}
            </span>
          </div>
          <div class="mt-2 h-1.5 overflow-hidden rounded-full bg-n-alpha-3">
            <div
              class="h-full rounded-full bg-n-blue-9 transition-all duration-300 ease-out"
              :style="{ width: `${progressPercentage}%` }"
            />
          </div>
        </div>
      </div>
    </div>
  </Transition>
  <woot-modal
    v-model:show="showCustomTimeSnoozeModal"
    size="w-[calc(100vw-2rem)] max-w-[32rem]"
    @close="hideCustomSnoozeModal"
  >
    <CustomSnoozeModal
      @close="hideCustomSnoozeModal"
      @choose-time="customSnoozeTime"
    />
  </woot-modal>
  <ConversationStatusReasonDialog ref="statusReasonDialogRef" />
  <Dialog
    ref="closeConfirmationDialogRef"
    type="alert"
    :title="$t('BULK_ACTION.CLOSE_CONFIRMATION.TITLE')"
    :description="
      $t('BULK_ACTION.CLOSE_CONFIRMATION.DESCRIPTION', {
        count: selectedCount,
      }) +
      (isSearchCapped
        ? ` ${$t('BULK_ACTION.CLOSE_CONFIRMATION.SEARCH_CAPPED', { count: selectedCount })}`
        : '')
    "
    :confirm-button-label="$t('BULK_ACTION.CLOSE_CONFIRMATION.CONFIRM')"
    @confirm="confirmClose"
    @close="cancelClose"
  />
</template>
