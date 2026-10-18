<script setup>
import { computed } from 'vue';
import { formatNumber } from '@chatwoot/utils';

const props = defineProps({
  conversationCount: { type: Number, default: 0 },
  isListLoading: { type: Boolean, default: false },
  isSearchResult: { type: Boolean, default: false },
  isFiltered: { type: Boolean, default: true },
  // The search found more than it returns (it only reads the newest matches): shown as "100+".
  isCountApproximate: { type: Boolean, default: false },
});

const shouldShowCount = computed(
  () => !props.isListLoading && (props.isFiltered || props.isSearchResult)
);

const formattedConversationCount = computed(
  () =>
    `${formatNumber(props.conversationCount || 0)}${
      props.isCountApproximate ? '+' : ''
    }`
);
</script>

<template>
  <div
    data-test-id="conversation-count-row"
    class="inline-flex min-w-0 shrink-0 items-center text-xxs leading-4 text-n-slate-10"
  >
    <span
      v-if="shouldShowCount"
      data-test-id="conversation-count"
      class="truncate rounded-md bg-n-alpha-2 px-1.5 py-0.5 text-[11px] leading-none font-medium tabular-nums text-n-slate-11"
      :title="String(conversationCount || 0)"
    >
      <template v-if="isSearchResult">
        {{
          $t('CHAT_LIST.LOCAL_SEARCH.RESULT_COUNT', {
            count: formattedConversationCount,
          })
        }}
      </template>
      <template v-else>
        {{
          $t('CHAT_LIST.TOTAL_COUNT', {
            count: formattedConversationCount,
          })
        }}
      </template>
    </span>
  </div>
</template>
