<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const props = defineProps({
  assistant: {
    type: Object,
    required: true,
  },
  canToggle: {
    type: Boolean,
    default: false,
  },
  toggling: {
    type: Boolean,
    default: false,
  },
  // How many agents are switched on in the workspace: with two or more, the
  // AI chooses among them by their description.
  enabledCount: { type: Number, default: 0 },
});

const emit = defineEmits(['open', 'toggleActive']);

const { t } = useI18n();

// The value the admin just picked, shown while the save runs (the parent
// marks the card as `toggling`). When it fails, or when the parent asks for a
// confirmation first, the switch stays on the stored value.
const pendingActive = ref(null);

const storedActive = computed(() => props.assistant?.active !== false);
const isActive = computed(() =>
  props.toggling && pendingActive.value !== null
    ? pendingActive.value
    : storedActive.value
);

const agentName = computed(() => props.assistant?.name || '');
const routingDescription = computed(() =>
  String(props.assistant?.routing_description || '').trim()
);

// A switched-on agent without a description is never chosen when several agents are on.
const hintsNoCard = computed(
  () => isActive.value && !routingDescription.value && props.enabledCount >= 2
);

const statusLabel = computed(() =>
  t(
    isActive.value
      ? 'CAPTAIN.ASSISTANTS.ROUTING.ACTIVE_STATUS'
      : 'CAPTAIN.ASSISTANTS.ROUTING.INACTIVE_STATUS'
  )
);

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
    class="group flex min-h-32 w-full cursor-pointer flex-col gap-3 rounded-xl bg-n-solid-2 px-5 py-4 outline outline-1 -outline-offset-1 outline-n-weak transition-colors hover:bg-n-alpha-2 focus-visible:outline-n-brand"
    data-testid="agent-gallery-card"
    @click="handleOpen"
    @keydown.enter.self.prevent="handleOpen"
    @keydown.space.self.prevent="handleOpen"
  >
    <div class="flex items-center justify-between gap-3">
      <div class="flex min-w-0 items-center gap-3">
        <Avatar
          :src="assistant.avatar_url || ''"
          :name="agentName"
          :size="40"
          icon-name="i-woot-captain"
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
        </div>
      </div>
      <div v-if="canToggle" class="flex shrink-0 items-center gap-2">
        <Switch
          :model-value="isActive"
          :disabled="toggling"
          :aria-label="t('CAPTAIN.ASSISTANTS.ROUTING.ACTIVE')"
          data-testid="agent-active-switch"
          @update:model-value="handleToggle"
          @click.stop
        />
      </div>
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
      class="mb-0 text-body-para"
      :class="hintsNoCard ? 'text-n-amber-11' : 'text-n-slate-10'"
      data-testid="agent-description-hint"
    >
      {{
        hintsNoCard
          ? t('CAPTAIN.GALLERY.CARD.NO_CARD_HINT')
          : t('CAPTAIN.GALLERY.CARD.NO_DESCRIPTION')
      }}
    </p>
  </div>
</template>
