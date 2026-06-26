<script setup>
import { ref, computed, onMounted, onUnmounted, useAttrs } from 'vue';
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
import ConversationStatusReasonDialog from 'dashboard/components-next/ConversationWorkflow/ConversationStatusReasonDialog.vue';

const props = defineProps({
  conversations: {
    type: Array,
    default: () => [],
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
  if (!bulkActionRun.value?.failed_count) return '';

  return t('BULK_ACTION.PROGRESS.FAILED', {
    count: bulkActionRun.value.failed_count,
  });
});

async function resolveStatusReason(status) {
  const result = await statusReasonDialogRef.value?.open({ status });
  if (result === statusReasonDialogRef.value?.CANCELLED) {
    return { cancelled: true };
  }

  return { statusReason: result };
}

async function updateConversations(status, snoozedUntil = null) {
  if (bulkActionUiFlags.value.isUpdating) return;

  const { cancelled, statusReason } = await resolveStatusReason(status);
  if (cancelled) return;

  emit('updateConversations', status, snoozedUntil, statusReason);
}

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
  emitter.off(CMD_BULK_ACTION_SNOOZE_CONVERSATION, onCmdSnoozeConversation);
  emitter.off(CMD_BULK_ACTION_REOPEN_CONVERSATION, onCmdReopenConversation);
  emitter.off(CMD_BULK_ACTION_RESOLVE_CONVERSATION, onCmdResolveConversation);
});
</script>

<template>
  <Transition
    enter-active-class="transition-all duration-200 ease-out origin-bottom"
    enter-from-class="opacity-0 scale-95 translate-y-2"
    enter-to-class="opacity-100 scale-100 translate-y-0"
    leave-active-class="transition-all duration-150 ease-in origin-bottom"
    leave-from-class="opacity-100 scale-100 translate-y-0"
    leave-to-class="opacity-0 scale-95 translate-y-2"
  >
    <div
      v-if="conversations.length > 0"
      v-bind="attrs"
      class="px-2 absolute bottom-20 sm:bottom-4 left-1/2 -translate-x-1/2 z-30 w-full origin-bottom pointer-events-none"
    >
      <div class="pointer-events-auto mx-auto max-w-4xl">
        <div
          v-if="allConversationsSelected"
          class="bg-n-amber-2 outline -outline-offset-1 outline-1 outline-n-amber-5 rounded-lg text-sm mb-2 py-1.5 px-2 text-n-amber-text"
        >
          {{ $t('BULK_ACTION.ALL_CONVERSATIONS_SELECTED_ALERT') }}
        </div>
        <div
          class="flex items-center justify-between p-2 bg-n-button-color outline outline-1 -outline-offset-1 rounded-[10px] outline-n-weak shadow-[0_0_12px_0_rgba(27,40,59,0.08)]"
        >
          <div class="ltr:ml-0.5 rtl:mr-0.5 flex items-center gap-1">
            <label class="cursor-pointer flex items-center gap-1.5">
              <Checkbox
                v-model="allSelected"
                :indeterminate="!allConversationsSelected"
                :disabled="bulkActionUiFlags.isUpdating"
              />
              <span class="cursor-pointer text-sm text-n-slate-12">
                {{
                  $t('BULK_ACTION.CONVERSATIONS_SELECTED', {
                    conversationCount: conversations.length,
                  })
                }}
              </span>
            </label>
            <div class="w-px h-3 bg-n-weak rounded-lg ltr:ml-1 rtl:mr-1" />
            <NextButton
              :label="$t('BULK_ACTION.CLEAR_SELECTION')"
              ghost
              class="!text-n-blue-11 !px-1 !h-6"
              sm
              :disabled="bulkActionUiFlags.isUpdating"
              @click="allSelected = false"
            />
          </div>
          <div class="flex items-center gap-2">
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
              :conversation-count="conversations.length"
              :disabled="bulkActionUiFlags.isUpdating"
              @select="assignAgent"
            />
            <BulkTeamActions
              :conversation-count="conversations.length"
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
</template>
