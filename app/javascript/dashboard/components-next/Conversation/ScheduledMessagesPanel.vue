<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TouchEditorDrawer from 'dashboard/components-next/Outbound/TouchEditorDrawer.vue';
import TouchesAPI from 'dashboard/api/touches';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import {
  consumeScheduledMessageDraft,
  useScheduledMessageDraft,
} from 'dashboard/composables/useScheduledMessageDraft';

const props = defineProps({
  conversationId: {
    type: [Number, String],
    default: '',
  },
  remindableId: {
    type: [Number, String],
    required: true,
  },
  remindableType: {
    type: String,
    required: true,
  },
});

const { t, locale } = useI18n();
const { currentAccount } = useAccount();
const messages = ref([]);
const isLoading = ref(false);
const cancellingId = ref(null);
const isEditorOpen = ref(false);
const editingMessage = ref(null);
const initialBody = ref('');
const initialAttachments = ref([]);
const pendingDraft = useScheduledMessageDraft();
let requestGeneration = 0;

const accountTimezone = computed(
  () => currentAccount.value?.reporting_timezone || 'UTC'
);
const scheduledMessages = computed(() =>
  messages.value.filter(message => {
    const metadata = message.metadata || {};
    const isManual =
      !message.reminder_group_id &&
      !metadata.automation_rule_id &&
      metadata.touch_source !== 'automation';
    return (
      isManual && ['draft', 'pending', 'processing'].includes(message.status)
    );
  })
);

const formatDateTime = value => {
  if (!value) return '—';

  return new Intl.DateTimeFormat(locale.value, {
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    month: 'short',
    timeZone: accountTimezone.value,
    timeZoneName: 'short',
  }).format(new Date(value));
};

const preview = message =>
  message.body ||
  (message.instructions
    ? t('CONVERSATION.SCHEDULED_MESSAGES.AI_PREVIEW')
    : t('CONVERSATION.SCHEDULED_MESSAGES.NO_CONTENT'));

const fetchMessages = async () => {
  requestGeneration += 1;
  const generation = requestGeneration;
  if (!props.remindableId) {
    messages.value = [];
    isLoading.value = false;
    return;
  }

  messages.value = [];
  isLoading.value = true;
  try {
    const { data } = await TouchesAPI.get({
      ...(props.conversationId
        ? { conversation_id: props.conversationId }
        : {}),
      remindable_id: props.remindableId,
      remindable_type: props.remindableType,
    });
    if (generation === requestGeneration) {
      messages.value = data.payload || [];
    }
  } catch (error) {
    if (generation === requestGeneration) {
      useAlert(
        error?.message || t('CONVERSATION.SCHEDULED_MESSAGES.LOAD_ERROR')
      );
    }
  } finally {
    if (generation === requestGeneration) {
      isLoading.value = false;
    }
  }
};

const openEditor = (message, draft = null) => {
  editingMessage.value = message || null;
  initialBody.value = message ? '' : draft?.body || '';
  initialAttachments.value = message ? [] : draft?.attachments || [];
  isEditorOpen.value = true;
};

const cancelMessage = async message => {
  cancellingId.value = message.id;
  try {
    await TouchesAPI.cancel(message.id, {
      reason: 'cancelled_from_conversation',
    });
    useAlert(t('CONVERSATION.SCHEDULED_MESSAGES.CANCELLED'));
    await fetchMessages();
  } catch (error) {
    useAlert(
      error?.message || t('CONVERSATION.SCHEDULED_MESSAGES.CANCEL_ERROR')
    );
  } finally {
    cancellingId.value = null;
  }
};

const handleSaved = async () => {
  editingMessage.value = null;
  await fetchMessages();
};

const consumeDraft = () => {
  const draft = consumeScheduledMessageDraft({
    accountId: currentAccount.value?.id,
    conversationId: props.conversationId,
    remindableId: props.remindableId,
    remindableType: props.remindableType,
  });
  if (draft) openEditor(null, draft);
};

watch(
  () => [props.conversationId, props.remindableId, props.remindableType],
  () => {
    editingMessage.value = null;
    isEditorOpen.value = false;
    fetchMessages();
    consumeDraft();
  },
  { immediate: true }
);

watch(() => pendingDraft.value, consumeDraft);
</script>

<template>
  <div class="flex min-h-full flex-1 flex-col bg-n-surface-1 p-4">
    <div class="flex items-start justify-between gap-3">
      <div class="min-w-0">
        <p class="mb-1 text-sm font-semibold text-n-slate-12">
          {{ $t('CONVERSATION.SCHEDULED_MESSAGES.TITLE') }}
        </p>
        <p class="mb-0 text-sm text-n-slate-11">
          {{ $t('CONVERSATION.SCHEDULED_MESSAGES.DESCRIPTION') }}
        </p>
      </div>
      <Button
        size="sm"
        icon="i-lucide-clock-plus"
        :label="$t('CONVERSATION.SCHEDULED_MESSAGES.CREATE')"
        @click="openEditor()"
      />
    </div>

    <div
      v-if="isLoading"
      class="flex items-center gap-2 py-6 text-sm text-n-slate-11"
    >
      <Spinner class="!h-4 !w-4" />
      <span>{{ $t('CONVERSATION.SCHEDULED_MESSAGES.LOADING') }}</span>
    </div>

    <div
      v-else-if="!scheduledMessages.length"
      class="mt-5 rounded-xl bg-n-alpha-black2 p-4 text-sm text-n-slate-11"
    >
      {{ $t('CONVERSATION.SCHEDULED_MESSAGES.EMPTY') }}
    </div>

    <div v-else class="mt-5 grid gap-3">
      <div
        v-for="message in scheduledMessages"
        :key="message.id"
        class="rounded-xl bg-n-alpha-black2 p-3"
      >
        <p class="mb-1 line-clamp-2 text-sm font-medium text-n-slate-12">
          {{ preview(message) }}
        </p>
        <p class="mb-3 text-xs text-n-slate-10">
          {{ formatDateTime(message.scheduled_at) }}
        </p>
        <div class="flex items-center gap-2">
          <Button
            size="sm"
            color="slate"
            variant="faded"
            :label="$t('CONVERSATION.SCHEDULED_MESSAGES.EDIT')"
            @click="openEditor(message)"
          />
          <Button
            size="sm"
            color="ruby"
            variant="faded"
            :is-loading="cancellingId === message.id"
            :label="$t('CONVERSATION.SCHEDULED_MESSAGES.CANCEL')"
            @click="cancelMessage(message)"
          />
        </div>
      </div>
    </div>

    <TouchEditorDrawer
      v-model="isEditorOpen"
      :conversation-id="conversationId"
      :remindable-id="remindableId"
      :remindable-type="remindableType"
      :touch="editingMessage"
      :initial-body="initialBody"
      :initial-attachments="initialAttachments"
      @saved="handleSaved"
    />
  </div>
</template>
