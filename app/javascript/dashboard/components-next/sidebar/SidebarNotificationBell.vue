<script setup>
import { computed } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';
import SidebarUnreadBadge from './SidebarUnreadBadge.vue';

const props = defineProps({
  isCollapsed: {
    type: Boolean,
    default: true,
  },
  label: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['openNotificationPanel']);

const notificationMetadata = useMapGetter('notifications/getMeta');
const unreadCount = computed(() => {
  return Number(notificationMetadata.value.unreadCount) || 0;
});
</script>

<template>
  <li class="m-0 w-full list-none">
    <button
      type="button"
      data-notification-panel-trigger
      class="relative flex items-center rounded-lg text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12"
      :class="
        props.isCollapsed
          ? 'size-9 justify-center'
          : 'h-8 w-full gap-2 px-2 text-sm'
      "
      :title="props.label"
      @click="emit('openNotificationPanel')"
    >
      <span class="i-lucide-bell size-4 shrink-0" />
      <span
        v-if="!props.isCollapsed"
        class="min-w-0 flex-1 truncate text-start"
      >
        {{ props.label }}
      </span>
      <SidebarUnreadBadge
        :value="unreadCount"
        :class="
          props.isCollapsed
            ? 'absolute -right-1.5 -top-1 min-w-5 text-center'
            : 'shrink-0'
        "
      />
    </button>
  </li>
</template>
