<script setup>
import { toRef } from 'vue';
import { useChannelIcon } from './provider';
import Icon from 'next/icon/Icon.vue';

const props = defineProps({
  inbox: {
    type: Object,
    required: true,
  },
  fallbackIcon: {
    type: String,
    default: 'i-ri-global-fill',
  },
  fallbackIconClass: {
    type: String,
    default: '',
  },
});

const channelIcon = useChannelIcon(
  toRef(props, 'inbox'),
  toRef(props, 'fallbackIcon')
);
</script>

<template>
  <Icon
    :icon="channelIcon"
    :class="channelIcon === fallbackIcon ? fallbackIconClass : undefined"
  />
</template>
