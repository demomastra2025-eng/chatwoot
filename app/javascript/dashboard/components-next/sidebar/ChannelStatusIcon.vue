<script setup>
import { computed } from 'vue';
import ChannelIcon from 'next/icon/ChannelIcon.vue';
import Icon from 'next/icon/Icon.vue';
import {
  hasWhatsappWebConnectionIssue,
  isWhatsappWebReconnecting,
} from 'dashboard/helper/whatsappWeb';
import { hasTelegramPersonalConnectionIssue } from 'dashboard/helper/telegramPersonal';

const props = defineProps({
  inbox: {
    type: Object,
    required: true,
  },
});

const hasConnectionIssue = computed(() => {
  return (
    hasWhatsappWebConnectionIssue(props.inbox) ||
    hasTelegramPersonalConnectionIssue(props.inbox)
  );
});

const isReconnecting = computed(() => {
  return isWhatsappWebReconnecting(props.inbox);
});
</script>

<template>
  <Icon
    v-if="isReconnecting"
    icon="i-lucide-refresh-cw"
    class="size-[14px] text-n-amber-11 animate-spin"
  />
  <Icon
    v-else-if="hasConnectionIssue"
    icon="i-lucide-triangle-alert"
    class="size-[14px] text-n-ruby-9"
  />
  <ChannelIcon v-else :inbox="inbox" class="size-4" />
</template>
