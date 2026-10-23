<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { picoSearch } from '@scmmishra/pico-search';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import { useMapGetter, useStoreGetters } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import ChannelName from './components/ChannelName.vue';
import ChannelIcon from 'next/icon/ChannelIcon.vue';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { isInboxPendingDeletion } from 'dashboard/helper/whatsappWeb';
import { getInboxListStatus } from './helpers/inboxListStatus';
import { getInboxListSubtitle } from './helpers/inboxListSubtitle';

const STATUS_BADGE_CLASSES = {
  teal: 'bg-n-teal-3 text-n-teal-11 border-n-teal-5',
  amber: 'bg-n-amber-3 text-n-amber-11 border-n-amber-5',
  ruby: 'bg-n-ruby-3 text-n-ruby-11 border-n-ruby-5',
};

const STATUS_HINT_CLASSES = {
  amber: 'text-n-amber-11',
  ruby: 'text-n-ruby-11',
};

const getters = useStoreGetters();
const { accountScopedRoute } = useAccount();
const { t } = useI18n();

const searchQuery = ref('');

const inboxes = useMapGetter('inboxes/getInboxes');

const getCapabilityChips = inbox => {
  const chips = [];

  if (inbox.captain_assistant?.name) {
    chips.push(
      t('INBOX_MGMT.LIST.CHIPS.CAPTAIN', {
        name: inbox.captain_assistant.name,
      })
    );
  }

  if (
    inbox.greeting_enabled &&
    ![INBOX_TYPES.VOICE, INBOX_TYPES.EMAIL].includes(inbox.channel_type)
  ) {
    chips.push(t('INBOX_MGMT.LIST.CHIPS.GREETING'));
  }

  // A voice channel is all about calls, so the tag would say nothing new.
  if (inbox.calling_enabled && inbox.channel_type !== INBOX_TYPES.VOICE) {
    chips.push(t('INBOX_MGMT.LIST.CHIPS.CALLS'));
  }

  return chips;
};

const buildCard = inbox => ({
  status: getInboxListStatus(inbox),
  subtitle: getInboxListSubtitle(inbox, t),
  chips: getCapabilityChips(inbox),
});

const inboxesList = computed(() => {
  return (inboxes.value || [])
    .slice()
    .sort((a, b) => a.name.localeCompare(b.name));
});

const searchableInboxes = computed(() => {
  return inboxesList.value.map(inbox => {
    const card = buildCard(inbox);
    const { status } = card;

    return {
      ...inbox,
      card,
      search_text: [
        card.subtitle?.text,
        card.chips.join(' '),
        t(status.labelKey),
        status.hintKey ? t(status.hintKey) : '',
      ]
        .filter(Boolean)
        .join(' '),
    };
  });
});

const filteredInboxesList = computed(() => {
  const visibleInboxes = searchableInboxes.value.filter(
    inbox => !isInboxPendingDeletion(inbox)
  );
  const query = searchQuery.value.trim();
  if (!query) return visibleInboxes;
  return picoSearch(visibleInboxes, query, [
    'name',
    'channel_type',
    'search_text',
  ]);
});

const showAddCard = computed(() => !searchQuery.value.trim());

const uiFlags = computed(() => getters['inboxes/getUIFlags'].value);
</script>

<template>
  <SettingsLayout :is-loading="uiFlags.isFetching">
    <template #header>
      <BaseSettingsHeader
        v-model:search-query="searchQuery"
        :title="$t('INBOX_MGMT.HEADER')"
        :description="$t('INBOX_MGMT.DESCRIPTION')"
        :link-text="$t('INBOX_MGMT.LEARN_MORE')"
        :search-placeholder="$t('INBOX_MGMT.SEARCH_PLACEHOLDER')"
        feature-name="inboxes"
      >
        <template v-if="inboxesList.length" #count>
          <span class="text-body-main text-n-slate-11">
            {{ $t('INBOX_MGMT.COUNT', { n: filteredInboxesList.length }) }}
          </span>
        </template>
        <template #actions>
          <router-link :to="accountScopedRoute('settings_inbox_new')">
            <Button
              :label="$t('INBOX_MGMT.LIST.CREATE_CHANNEL')"
              icon="i-lucide-plus"
              size="sm"
            />
          </router-link>
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
      <div
        v-else
        class="grid grid-cols-1 gap-4 pt-2 sm:grid-cols-2 xl:grid-cols-3"
      >
        <router-link
          v-for="inbox in filteredInboxesList"
          :key="inbox.id"
          :to="accountScopedRoute('settings_inbox_show', { inboxId: inbox.id })"
          class="group flex min-h-48 flex-col justify-between rounded-xl bg-n-solid-2 px-6 py-5 outline outline-1 -outline-offset-1 outline-n-container transition-colors hover:bg-n-alpha-2 hover:outline-n-brand/50 focus-visible:outline-n-brand"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="flex min-w-0 items-center gap-3">
              <div
                class="grid size-11 shrink-0 place-items-center rounded-full bg-n-alpha-3"
              >
                <ChannelIcon class="size-6 text-n-slate-10" :inbox="inbox" />
              </div>
              <div class="min-w-0">
                <span
                  class="block truncate text-heading-3 text-n-slate-12 capitalize"
                >
                  {{ inbox.name }}
                </span>
                <ChannelName
                  :channel-type="inbox.channel_type"
                  :medium="inbox.medium"
                  class="text-body-main text-n-slate-11"
                />
              </div>
            </div>
            <span
              class="shrink-0 rounded-full border px-2 py-0.5 text-xs font-medium"
              :class="STATUS_BADGE_CLASSES[inbox.card.status.tone]"
              data-test-id="inbox-status-badge"
            >
              {{ $t(inbox.card.status.labelKey) }}
            </span>
          </div>

          <div class="mt-4 flex flex-col gap-2 text-sm text-n-slate-11">
            <div
              v-if="inbox.card.subtitle"
              class="flex min-w-0 items-center gap-2"
              data-test-id="inbox-subtitle"
            >
              <Icon
                :icon="inbox.card.subtitle.icon"
                class="size-4 shrink-0 text-n-slate-9"
              />
              <span
                class="min-w-0 truncate text-n-slate-12"
                :title="inbox.card.subtitle.text"
              >
                {{ inbox.card.subtitle.text }}
              </span>
            </div>

            <div v-if="inbox.card.chips.length" class="flex flex-wrap gap-1.5">
              <span
                v-for="chip in inbox.card.chips"
                :key="chip"
                class="rounded-md bg-n-alpha-2 px-2 py-1 text-xs text-n-slate-11"
              >
                {{ chip }}
              </span>
            </div>

            <p
              v-if="inbox.card.status.hintKey"
              class="mb-0 text-xs"
              :class="STATUS_HINT_CLASSES[inbox.card.status.hintTone]"
              data-test-id="inbox-status-hint"
            >
              {{ $t(inbox.card.status.hintKey) }}
            </p>
          </div>

          <div
            class="mt-4 flex items-center justify-between border-t border-n-weak pt-3 text-sm font-medium text-n-brand"
          >
            <span>{{ $t('INBOX_MGMT.LIST.OPEN_SETTINGS') }}</span>
            <Icon
              icon="i-lucide-arrow-right"
              class="size-4 transition group-hover:translate-x-0.5"
            />
          </div>
        </router-link>

        <router-link
          v-if="showAddCard"
          :to="accountScopedRoute('settings_inbox_new')"
          class="flex min-h-48 flex-col items-center justify-center gap-3 rounded-xl bg-n-alpha-2 px-6 py-5 text-center outline-dashed outline-1 -outline-offset-1 outline-n-weak transition-colors hover:bg-n-brand/5 hover:outline-n-brand focus-visible:outline-n-brand"
        >
          <span
            class="grid size-12 place-items-center rounded-full bg-n-brand/10 text-n-brand"
          >
            <Icon icon="i-lucide-plus" class="size-6" />
          </span>
          <span class="text-heading-3 text-n-slate-12">
            {{ $t('INBOX_MGMT.LIST.CREATE_CHANNEL') }}
          </span>
          <span class="max-w-56 text-body-main text-n-slate-11">
            {{ $t('INBOX_MGMT.LIST.CREATE_CHANNEL_HELP') }}
          </span>
        </router-link>
      </div>
    </template>
  </SettingsLayout>
</template>
