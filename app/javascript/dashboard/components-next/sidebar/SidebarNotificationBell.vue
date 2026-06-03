<script setup>
import { computed } from 'vue';
import { useRoute } from 'vue-router';
import { useMapGetter } from 'dashboard/composables/store';
import SidebarUnreadBadge from './SidebarUnreadBadge.vue';

const emit = defineEmits(['openNotificationPanel']);

const notificationMetadata = useMapGetter('notifications/getMeta');
const route = useRoute();
const unreadCount = computed(() => {
  return Number(notificationMetadata.value.unreadCount) || 0;
});

function openNotificationPanel() {
  if (route.name !== 'notifications_index') {
    emit('openNotificationPanel');
  }
}
</script>

<template>
  <button
    class="size-8 rounded-lg hover:bg-n-alpha-1 flex-shrink-0 grid place-content-center relative"
    @click="openNotificationPanel"
  >
    <span class="i-lucide-bell size-4" />
    <SidebarUnreadBadge
      :value="unreadCount"
      class="absolute -top-1 -right-1.5 min-w-5 text-center"
    />
  </button>
</template>
