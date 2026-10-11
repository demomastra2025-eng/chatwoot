<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useMapGetter } from 'dashboard/composables/store';
import ChannelIcon from 'dashboard/components-next/icon/ChannelIcon.vue';
import { useCaptainChannelMatrixStore } from 'dashboard/store/captain/channelMatrix';
import { agentChannelSummary } from 'dashboard/helper/captainChannelMatrix';

// «Каналы» block of the agent page side column: read-only summary of where
// the agent works and where it answers first. Editing lives on the «Каналы»
// page (admins).
const props = defineProps({
  assistant: { type: Object, required: true },
  canConfigure: { type: Boolean, default: false },
});

const { t } = useI18n();
const route = useRoute();
const inboxes = useMapGetter('inboxes/getInboxes');
const matrixStore = useCaptainChannelMatrixStore();

// The matrix is admin-only; everybody else gets the summary from the
// assistant JSON and the inbox list.
const matrix = computed(() =>
  props.canConfigure ? matrixStore.getMatrix || null : null
);

const summary = computed(() =>
  agentChannelSummary({
    assistant: props.assistant,
    matrix: matrix.value,
    inboxes: inboxes.value || [],
  })
);

const isAllChannels = computed(() => summary.value.scope === 'all');
const channels = computed(() => summary.value.channels || []);
const mainChannelNames = computed(() =>
  channels.value
    .filter(channel => channel.isMain)
    .map(channel => channel.name)
    .filter(Boolean)
    .join(', ')
);

const channelsRoute = computed(() => ({
  name: 'captain_channels_index',
  params: { accountId: route.params.accountId },
}));
</script>

<template>
  <section
    class="flex flex-col outline outline-1 -outline-offset-1 outline-n-container rounded-xl bg-n-solid-2 divide-y divide-n-weak"
    data-test="agent-channels-block"
  >
    <div class="flex items-center justify-between gap-3 px-5 py-4">
      <h3 class="mb-0 text-heading-2 text-n-slate-12">
        {{ t('CAPTAIN.AGENT_PAGE.CHANNELS.TITLE') }}
      </h3>
      <router-link
        v-if="canConfigure"
        :to="channelsRoute"
        class="shrink-0 text-sm text-n-brand hover:underline"
        data-test="agent-channels-configure"
      >
        {{ t('CAPTAIN.AGENT_PAGE.CHANNELS.CONFIGURE') }}
      </router-link>
    </div>
    <div class="grid gap-4 px-5 py-4">
      <p
        v-if="isAllChannels"
        class="mb-0 text-body-main text-n-slate-12"
        data-test="agent-channels-all"
      >
        {{ t('CAPTAIN.AGENT_PAGE.CHANNELS.ALL') }}
      </p>
      <ul
        v-else-if="channels.length"
        class="m-0 flex list-none flex-col gap-2 p-0"
        data-test="agent-channels-list"
      >
        <li
          v-for="channel in channels"
          :key="channel.inboxId"
          class="flex min-w-0 items-center gap-2 text-body-main text-n-slate-12"
        >
          <ChannelIcon
            :inbox="{ channel_type: channel.channelType }"
            class="size-4 shrink-0 text-n-slate-11"
          />
          <span class="min-w-0 truncate">{{ channel.name }}</span>
        </li>
      </ul>
      <p
        v-else
        class="mb-0 text-body-main text-n-slate-11"
        data-test="agent-channels-none"
      >
        {{ t('CAPTAIN.AGENT_PAGE.CHANNELS.NONE') }}
      </p>
      <p
        v-if="mainChannelNames"
        class="mb-0 text-body-main text-n-slate-11"
        data-test="agent-channels-main"
      >
        {{
          t('CAPTAIN.AGENT_PAGE.CHANNELS.MAIN_IN', {
            channels: mainChannelNames,
          })
        }}
      </p>
    </div>
  </section>
</template>
