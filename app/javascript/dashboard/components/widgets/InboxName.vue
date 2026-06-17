<script setup>
import ChannelIcon from 'dashboard/components-next/icon/ChannelIcon.vue';

defineProps({
  inbox: {
    type: Object,
    default: () => {},
  },
  compact: {
    type: Boolean,
    default: false,
  },
});
</script>

<template>
  <div :title="inbox.name" class="flex items-center gap-0.5 min-w-0">
    <ChannelIcon
      :inbox="inbox"
      class="flex-shrink-0 text-n-slate-11"
      :class="compact ? 'size-3' : 'size-4'"
    />
    <span
      class="truncate text-n-slate-11"
      :class="compact ? 'text-xxs leading-3' : 'text-label-small'"
    >
      {{ inbox.name }}
    </span>
  </div>
</template>
