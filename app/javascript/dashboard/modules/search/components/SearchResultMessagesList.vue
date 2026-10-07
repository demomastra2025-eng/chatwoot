<script setup>
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store.js';

import SearchResultMessageItem from './SearchResultMessageItem.vue';
import SearchResultSection from './SearchResultSection.vue';
import MessageContent from './MessageContent.vue';

defineProps({
  messages: {
    type: Array,
    default: () => [],
  },
  query: {
    type: String,
    default: '',
  },
  isFetching: {
    type: Boolean,
    default: false,
  },
  // The search of the message text was cut short by its time limit.
  isPartial: {
    type: Boolean,
    default: false,
  },
  showTitle: {
    type: Boolean,
    default: true,
  },
});
const { t } = useI18n();

const accountId = useMapGetter('getCurrentAccountId');

const getName = message => {
  return message && message.sender && message.sender.name
    ? message.sender.name
    : t('SEARCH.BOT_LABEL');
};
</script>

<template>
  <SearchResultSection
    :title="$t('SEARCH.SECTION.MESSAGES')"
    :empty="!messages.length"
    :query="query"
    :show-title="showTitle"
    :is-fetching="isFetching"
  >
    <ul v-if="messages.length" class="space-y-3 list-none">
      <li v-for="message in messages" :key="message.id">
        <SearchResultMessageItem
          :id="message.conversationId"
          :communication-thread-id="message.communicationThreadId"
          :account-id="accountId"
          :inbox-id="message.inboxId"
          :created-at="message.createdAt"
          :message-id="message.id"
          :is-private="message.private"
          :attachments="message.attachments"
        >
          <MessageContent
            :author="getName(message)"
            :message="message"
            :search-term="query"
          />
        </SearchResultMessageItem>
      </li>
    </ul>
    <p
      v-if="isPartial && !isFetching"
      data-test="messages-partial"
      class="mt-3 text-xs text-n-amber-11"
    >
      {{ $t('SEARCH.MESSAGES_PARTIAL') }}
    </p>
  </SearchResultSection>
</template>
