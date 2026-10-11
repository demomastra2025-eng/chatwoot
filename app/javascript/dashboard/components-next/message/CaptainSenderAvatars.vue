<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import Avatar from 'next/avatar/Avatar.vue';

const props = defineProps({
  // Normalized council members: [{ id, name, avatarUrl }]
  contributors: { type: Array, default: () => [] },
  size: { type: Number, default: 24 },
  max: { type: Number, default: 3 },
});

const { t } = useI18n();

const visibleLimit = computed(() => Math.max(Math.floor(props.max) || 0, 1));

const visibleContributors = computed(() =>
  props.contributors.slice(0, visibleLimit.value)
);

const hiddenCount = computed(() =>
  Math.max(props.contributors.length - visibleLimit.value, 0)
);

const moreChipStyle = computed(() => ({
  width: `${props.size}px`,
  height: `${props.size}px`,
  fontSize: `${Math.max(Math.round(props.size / 2.5), 9)}px`,
}));

const contributorKey = (contributor, index) =>
  contributor?.id ?? `${contributor?.name || 'contributor'}-${index}`;
</script>

<template>
  <span
    class="inline-flex items-center -space-x-2 rtl:space-x-reverse"
    data-testid="captain-sender-avatars"
  >
    <Avatar
      v-for="(contributor, index) in visibleContributors"
      :key="contributorKey(contributor, index)"
      :name="contributor.name || ''"
      :src="contributor.avatarUrl || contributor.avatar_url || ''"
      :size="size"
      rounded-full
      class="rounded-full ring-2 ring-n-background"
    />
    <span
      v-if="hiddenCount > 0"
      class="relative inline-flex items-center justify-center flex-shrink-0 rounded-full ring-2 ring-n-background bg-n-slate-3 text-n-slate-11 font-medium tabular-nums leading-none select-none"
      :style="moreChipStyle"
      data-testid="captain-sender-avatars-more"
    >
      {{ t('CAPTAIN.CHAT_AVATARS.MORE', { count: hiddenCount }) }}
    </span>
  </span>
</template>
