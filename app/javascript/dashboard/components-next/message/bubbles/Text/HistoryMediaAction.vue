<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'next/button/Button.vue';
import ConversationAPI from 'dashboard/api/conversations';
import { useStore } from 'dashboard/composables/store';
import { useMessageContext } from '../../provider.js';

const { id, conversationId, contentAttributes, attachments } =
  useMessageContext();
const store = useStore();
const { t } = useI18n();
const loading = ref(false);
const failed = ref(false);
const unavailable = ref(false);
const sourceUnavailable = computed(() => {
  const attrs = contentAttributes.value || {};
  const history = attrs.historyAttachment || attrs.history_attachment;
  return (
    unavailable.value ||
    (history?.fetchState || history?.fetch_state) === 'unavailable'
  );
});

const visible = computed(() => {
  const attrs = contentAttributes.value || {};
  const history = attrs.historyAttachment || attrs.history_attachment;
  return (
    !attrs.deleted &&
    !attachments.value?.length &&
    Boolean(
      history?.unavailable ||
        attrs.telegramHistoryMediaIncomplete ||
        attrs.telegram_history_media_incomplete
    )
  );
});

const loadMedia = async () => {
  if (loading.value) return;
  loading.value = true;
  failed.value = false;
  unavailable.value = false;
  try {
    const { data } = await ConversationAPI.enrichHistoryMedia(
      conversationId.value,
      id.value
    );
    await store.dispatch('updateMessage', data);
    unavailable.value = !data.attachments?.length;
  } catch {
    failed.value = true;
  } finally {
    loading.value = false;
  }
};
</script>

<template>
  <div v-if="visible" class="flex flex-col items-start gap-1">
    <span
      v-if="failed || sourceUnavailable"
      class="text-xs text-n-slate-11"
      role="status"
    >
      {{
        t(
          sourceUnavailable
            ? 'HISTORY_MEDIA.UNAVAILABLE'
            : 'HISTORY_MEDIA.ERROR'
        )
      }}
    </span>
    <Button
      variant="link"
      size="sm"
      icon="i-lucide-download"
      :is-loading="loading"
      :disabled="loading"
      :label="
        t(
          failed || sourceUnavailable
            ? 'HISTORY_MEDIA.RETRY'
            : 'HISTORY_MEDIA.LOAD'
        )
      "
      @click="loadMedia"
    />
  </div>
</template>
