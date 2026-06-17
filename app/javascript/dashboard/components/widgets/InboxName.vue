<script setup>
import { computed } from 'vue';
import ChannelIcon from 'dashboard/components-next/icon/ChannelIcon.vue';

const props = defineProps({
  inbox: {
    type: Object,
    default: () => {},
  },
  compact: {
    type: Boolean,
    default: false,
  },
  maxLength: {
    type: Number,
    default: 0,
  },
});

const displayName = computed(() => {
  const name = props.inbox?.name || '';
  return props.maxLength > 0 && name.length > props.maxLength
    ? `${name.slice(0, props.maxLength)}…`
    : name;
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
      {{ displayName }}
    </span>
  </div>
</template>
