<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  accountId: { type: [Number, String], default: null },
  displayId: { type: [Number, String], default: null },
});

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const positiveId = value => {
  const id = Number(value);
  return Number.isSafeInteger(id) && id > 0 ? id : null;
};
const conversationRoute = computed(() => {
  const accountId = positiveId(props.accountId);
  const displayId = positiveId(props.displayId);
  if (!accountId || !displayId) return null;
  if (accountId !== positiveId(route?.params?.accountId)) return null;

  return {
    name: 'inbox_conversation',
    params: { accountId, conversation_id: displayId },
  };
});
const label = computed(() => {
  const displayId = positiveId(props.displayId);
  return displayId
    ? t('CRM.TIMELINE.CONVERSATION', { id: displayId })
    : t('CRM.GENERAL.LINKED_CONVERSATION');
});
const openConversation = () => {
  if (conversationRoute.value) router.push(conversationRoute.value);
};
</script>

<template>
  <Button
    v-if="conversationRoute"
    type="button"
    size="sm"
    color="slate"
    variant="ghost"
    :label="label"
    @click="openConversation"
  />
  <span v-else>{{ label }}</span>
</template>
