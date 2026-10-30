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

const emit = defineEmits(['clearSearch']);

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
      class="inline-flex min-w-0 items-center gap-1 rounded-md bg-n-alpha-2 px-1.5 py-0.5 text-[11px] leading-none font-medium tabular-nums text-n-slate-11"
      :title="String(conversationCount || 0)"
    >
      <span class="truncate">
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
      <button
        v-if="isSearchResult"
        type="button"
        data-test-id="clear-local-search-button"
        class="relative inline-flex size-3.5 shrink-0 items-center justify-center rounded-sm text-n-slate-10 transition-colors after:absolute after:-inset-1.5 hover:bg-n-alpha-3 hover:text-n-slate-12"
        :aria-label="$t('CHAT_LIST.LOCAL_SEARCH.CLEAR_BUTTON_LABEL')"
        :title="$t('CHAT_LIST.LOCAL_SEARCH.CLEAR_BUTTON_LABEL')"
        @click.stop="emit('clearSearch')"
      >
        <span class="i-lucide-x size-3" aria-hidden="true" />
      </button>
    </span>
  </div>
</template>
