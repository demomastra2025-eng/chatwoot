<script setup>
import Banner from 'dashboard/components-next/banner/Banner.vue';

const props = defineProps({
  actionLabel: {
    type: String,
    default: null,
  },
  description: {
    type: String,
    default: null,
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['reauthorize']);

const handleReauthorize = () => {
  if (!props.isLoading) emit('reauthorize');
};
</script>

<template>
  <Banner
    color="ruby"
    :action-label="actionLabel || $t('INBOX_MGMT.CLICK_TO_RECONNECT')"
    @action="handleReauthorize"
  >
    {{ description || $t('INBOX_MGMT.RECONNECTION_REQUIRED') }}
  </Banner>
</template>
