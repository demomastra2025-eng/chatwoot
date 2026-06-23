<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { messageTimestamp } from 'shared/helpers/timeHelper';
import { getLocalizedActivityMessage } from 'dashboard/helper/activityMessageHelper';
import { useMapGetter } from 'dashboard/composables/store';
import BaseBubble from './Base.vue';
import { useMessageContext } from '../provider.js';

const { content, createdAt } = useMessageContext();
const { t } = useI18n();
const accountLabels = useMapGetter('labels/getLabels');

const readableTime = computed(() =>
  messageTimestamp(createdAt.value, 'LLL d, h:mm a')
);

const displayContent = computed(() =>
  getLocalizedActivityMessage(content.value, t, { labels: accountLabels.value })
);
</script>

<template>
  <BaseBubble
    v-tooltip.top="readableTime"
    class="px-3 py-1 !rounded-xl flex min-w-0 items-center gap-2"
    data-bubble-name="activity"
  >
    <span
      v-dompurify-html="displayContent"
      class="whitespace-pre-line"
      :title="displayContent"
    />
  </BaseBubble>
</template>
