<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const props = defineProps({
  assistant: {
    type: Object,
    required: true,
  },
  // { mainCount, memberCount, scope } from agentChannelSummary; memberCount
  // is null when the agent works on all channels and the exact list is unknown.
  stats: {
    type: Object,
    default: null,
  },
  canToggle: {
    type: Boolean,
    default: false,
  },
  toggling: {
    type: Boolean,
    default: false,
  },
  isMain: { type: Boolean, default: false },
});

const emit = defineEmits(['open', 'toggleActive', 'makeMain']);

const { t } = useI18n();

// The value the admin just picked, shown until the save settles. When it
// fails the parent keeps the stored value and the switch falls back to it.
const pendingActive = ref(null);

const storedActive = computed(() => props.assistant?.active !== false);
const isActive = computed(() =>
  pendingActive.value === null ? storedActive.value : pendingActive.value
);

const agentName = computed(() => props.assistant?.name || '');
const routingDescription = computed(() =>
  String(props.assistant?.routing_description || '').trim()
);

const statusLabel = computed(() =>
  t(
    isActive.value
      ? 'CAPTAIN.ASSISTANTS.ROUTING.ACTIVE_STATUS'
      : 'CAPTAIN.ASSISTANTS.ROUTING.INACTIVE_STATUS'
  )
);

const channelsLine = computed(() => {
  const { stats } = props;
  if (!stats) return '';

  const main = Number(stats.mainCount) || 0;
  const hasMemberCount =
    stats.memberCount !== null && stats.memberCount !== undefined;

  if (!hasMemberCount) {
    return stats.scope === 'all'
      ? t('CAPTAIN.GALLERY.CARD.ALL_CHANNELS', { main })
      : '';
  }

  const total = Number(stats.memberCount) || 0;
  if (!total) return t('CAPTAIN.GALLERY.CARD.NO_CHANNELS');

  return t('CAPTAIN.GALLERY.CARD.CHANNELS_LINE', { main, total });
});

const handleOpen = () => {
  emit('open');
};

const handleToggle = value => {
  pendingActive.value = Boolean(value);
  emit('toggleActive', Boolean(value));
};

watch(
  () => props.toggling,
  (toggling, wasToggling) => {
    if (wasToggling && !toggling) pendingActive.value = null;
  }
);

watch(storedActive, () => {
  pendingActive.value = null;
});
</script>

<template>
  <div
    role="button"
    tabindex="0"
    class="group flex min-h-36 w-full cursor-pointer flex-col gap-3 rounded-xl bg-n-solid-2 px-5 py-4 outline outline-1 -outline-offset-1 outline-n-container transition-colors hover:bg-n-alpha-2 focus-visible:outline-n-brand"
    data-testid="agent-gallery-card"
    @click="handleOpen"
    @keydown.enter.self.prevent="handleOpen"
    @keydown.space.self.prevent="handleOpen"
  >
    <div class="flex items-start justify-between gap-3">
      <div class="flex min-w-0 items-center gap-3">
        <Avatar
          :src="assistant.avatar_url || ''"
          :name="agentName"
          :size="40"
          rounded-full
        />
        <div class="flex min-w-0 flex-col">
          <span
            class="block truncate text-heading-3 text-n-slate-12"
            :title="agentName"
          >
            {{ agentName }}
          </span>
          <span
            v-if="!canToggle"
            class="text-body-main text-n-slate-11"
            data-testid="agent-status"
          >
            {{ statusLabel }}
          </span>
          <span
            v-if="isMain"
            class="flex items-center gap-1 text-body-main text-n-amber-11"
            data-testid="agent-main-label"
          >
            <Icon icon="i-lucide-star" class="size-4 fill-current" />
            {{ t('CAPTAIN.GALLERY.CARD.MAIN') }}
          </span>
        </div>
      </div>
      <Switch
        v-if="canToggle"
        :model-value="isActive"
        :disabled="toggling || isMain"
        :aria-label="t('CAPTAIN.ASSISTANTS.ROUTING.ACTIVE')"
        class="mt-0.5"
        data-testid="agent-active-switch"
        @update:model-value="handleToggle"
        @click.stop
      />
      <button
        v-if="canToggle && !isMain && isActive"
        type="button"
        class="rounded-lg p-1 text-n-slate-11 hover:text-n-amber-11"
        :aria-label="t('CAPTAIN.GALLERY.CARD.MAKE_MAIN')"
        data-testid="agent-make-main"
        @click.stop="emit('makeMain')"
      >
        <Icon icon="i-lucide-star" class="size-5" />
      </button>
    </div>

    <p
      v-if="routingDescription"
      class="mb-0 line-clamp-2 break-words text-body-para text-n-slate-11"
      :title="routingDescription"
    >
      {{ routingDescription }}
    </p>
    <p
      v-else
      class="mb-0 text-body-para text-n-slate-10"
      data-testid="agent-description-hint"
    >
      {{ t('CAPTAIN.GALLERY.CARD.NO_DESCRIPTION') }}
    </p>

    <div
      v-if="channelsLine"
      class="mt-auto flex min-w-0 items-center gap-1.5 text-body-main text-n-slate-11"
      data-testid="agent-channels-line"
    >
      <Icon icon="i-lucide-messages-square" class="size-4 shrink-0" />
      <span class="truncate">{{ channelsLine }}</span>
    </div>
  </div>
</template>
