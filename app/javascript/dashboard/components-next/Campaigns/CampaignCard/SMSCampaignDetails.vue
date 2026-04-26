<script setup>
import { computed } from 'vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import { messageStamp } from 'shared/helpers/timeHelper';

import { useI18n } from 'vue-i18n';
const props = defineProps({
  sender: {
    type: Object,
    default: null,
  },
  aiSender: {
    type: Object,
    default: null,
  },
  inboxName: {
    type: String,
    default: '',
  },
  inboxIcon: {
    type: String,
    default: '',
  },
  scheduledAt: {
    type: Number,
    default: 0,
  },
});

const { t } = useI18n();

const senderName = computed(
  () => props.aiSender?.name || props.sender?.name || ''
);
const senderIcon = computed(() =>
  props.aiSender?.id ? 'i-lucide-bot' : 'i-lucide-user'
);
</script>

<template>
  <template v-if="senderName">
    <span class="flex-shrink-0 text-sm text-n-slate-11 whitespace-nowrap">
      {{ t('CAMPAIGN.LIVE_CHAT.CARD.CAMPAIGN_DETAILS.SENT_BY') }}
    </span>
    <div class="flex items-center gap-1.5 flex-shrink-0">
      <Icon :icon="senderIcon" class="flex-shrink-0 text-n-slate-12 size-3" />
      <span class="text-sm font-medium text-n-slate-12">
        {{ senderName }}
      </span>
    </div>
  </template>
  <span class="flex-shrink-0 text-sm text-n-slate-11 whitespace-nowrap">
    {{ t('CAMPAIGN.SMS.CARD.CAMPAIGN_DETAILS.SENT_FROM') }}
  </span>
  <div class="flex items-center gap-1.5 flex-shrink-0">
    <Icon :icon="inboxIcon" class="flex-shrink-0 text-n-slate-12 size-3" />
    <span class="text-sm font-medium text-n-slate-12">
      {{ inboxName }}
    </span>
  </div>

  <span class="flex-shrink-0 text-sm text-n-slate-11 whitespace-nowrap">
    {{ t('CAMPAIGN.SMS.CARD.CAMPAIGN_DETAILS.ON') }}
  </span>
  <span class="flex-1 text-sm font-medium truncate text-n-slate-12">
    {{ messageStamp(new Date(scheduledAt * 1000), 'LLL d, h:mm a') }}
  </span>
</template>
