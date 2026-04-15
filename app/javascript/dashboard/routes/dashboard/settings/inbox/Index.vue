<script setup>
import { computed, ref } from 'vue';
import { picoSearch } from '@scmmishra/pico-search';
import Avatar from 'next/avatar/Avatar.vue';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import { useMapGetter, useStoreGetters } from 'dashboard/composables/store';
import ChannelName from './components/ChannelName.vue';
import ChannelIcon from 'next/icon/ChannelIcon.vue';
import { isInboxPendingDeletion } from 'dashboard/helper/whatsappWeb';

const getters = useStoreGetters();

const searchQuery = ref('');

const inboxes = useMapGetter('inboxes/getInboxes');

const inboxesList = computed(() => {
  return inboxes.value?.slice().sort((a, b) => a.name.localeCompare(b.name));
});

const filteredInboxesList = computed(() => {
  const visibleInboxes = inboxesList.value.filter(
    inbox => !isInboxPendingDeletion(inbox)
  );
  const query = searchQuery.value.trim();
  if (!query) return visibleInboxes;
  return picoSearch(visibleInboxes, query, ['name', 'channel_type']);
});

const uiFlags = computed(() => getters['inboxes/getUIFlags'].value);
</script>

<template>
  <SettingsLayout
    :no-records-found="!inboxesList.length"
    :no-records-message="$t('INBOX_MGMT.LIST.404')"
    :is-loading="uiFlags.isFetching"
  >
    <template #header>
      <BaseSettingsHeader
        v-model:search-query="searchQuery"
        :title="$t('INBOX_MGMT.HEADER')"
        :description="$t('INBOX_MGMT.DESCRIPTION')"
        :link-text="$t('INBOX_MGMT.LEARN_MORE')"
        :search-placeholder="$t('INBOX_MGMT.SEARCH_PLACEHOLDER')"
        feature-name="inboxes"
      >
        <template v-if="inboxesList?.length" #count>
          <span class="text-body-main text-n-slate-11">
            {{ $t('INBOX_MGMT.COUNT', { n: inboxesList.length }) }}
          </span>
        </template>
      </BaseSettingsHeader>
    </template>
    <template #body>
      <span
        v-if="!filteredInboxesList.length && searchQuery"
        class="flex-1 flex items-center justify-center py-20 text-center text-body-main !text-base text-n-slate-11"
      >
        {{ $t('INBOX_MGMT.NO_RESULTS') }}
      </span>
      <div v-else class="divide-y divide-n-weak border-t border-n-weak">
        <div
          v-for="inbox in filteredInboxesList"
          :key="inbox.id"
          class="flex justify-between flex-row items-start gap-4 py-4"
        >
          <div class="flex items-center gap-4">
            <div
              v-if="inbox.avatar_url"
              class="bg-n-alpha-3 rounded-xl size-10 ring ring-n-solid-1 border border-n-strong shadow-sm grid place-items-center"
            >
              <Avatar
                :src="inbox.avatar_url"
                :name="inbox.name"
                :size="24"
                rounded-full
              />
            </div>
            <div
              v-else
              class="size-10 justify-center bg-n-alpha-3 rounded-xl ring ring-n-solid-1 border border-n-strong shadow-sm grid place-items-center"
            >
              <ChannelIcon class="size-6 text-n-slate-10" :inbox="inbox" />
            </div>
            <div class="flex flex-col items-start gap-1">
              <span class="block text-heading-3 text-n-slate-12 capitalize">
                {{ inbox.name }}
              </span>
              <ChannelName
                :channel-type="inbox.channel_type"
                :medium="inbox.medium"
                class="text-body-main text-n-slate-11"
              />
            </div>
          </div>
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
