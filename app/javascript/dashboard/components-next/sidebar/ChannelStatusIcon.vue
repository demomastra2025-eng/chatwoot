<script setup>
import { computed } from 'vue';
import ChannelIcon from 'next/icon/ChannelIcon.vue';
import Icon from 'next/icon/Icon.vue';
import { hasWhatsappWebConnectionIssue } from 'dashboard/helper/whatsappWeb';

const props = defineProps({
  inbox: {
    type: Object,
    required: true,
  },
});

const hasConnectionIssue = computed(() => {
  return hasWhatsappWebConnectionIssue(props.inbox);
});
</script>

<template>
  <Icon
    v-if="hasConnectionIssue"
    icon="i-lucide-triangle-alert"
    class="size-4 text-n-ruby-9"
  />
  <ChannelIcon v-else :inbox="inbox" class="size-4" />
</template>
