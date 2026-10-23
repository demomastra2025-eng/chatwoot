<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { CONNECTION_STATUS } from '../helpers/connectionStatus';

const props = defineProps({
  status: {
    type: String,
    default: CONNECTION_STATUS.DISCONNECTED,
  },
});

const { t } = useI18n();

const label = computed(() => {
  if (props.status === CONNECTION_STATUS.CONNECTED) {
    return t('INBOX_MGMT.EDIT.CONNECTION_STATUS.CONNECTED');
  }
  if (props.status === CONNECTION_STATUS.CONNECTING) {
    return t('INBOX_MGMT.EDIT.CONNECTION_STATUS.CONNECTING');
  }
  return t('INBOX_MGMT.EDIT.CONNECTION_STATUS.DISCONNECTED');
});

const badgeClass = computed(() => {
  if (props.status === CONNECTION_STATUS.CONNECTED) {
    return 'bg-n-teal-9/10 text-n-teal-11';
  }
  if (props.status === CONNECTION_STATUS.CONNECTING) {
    return 'bg-n-amber-9/10 text-n-amber-11';
  }
  return 'bg-n-ruby-9/10 text-n-ruby-11';
});
</script>

<template>
  <span
    class="inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium"
    :class="badgeClass"
    data-testid="connection-status"
    :data-status="status"
  >
    <span class="size-1.5 rounded-full bg-current" />
    {{ label }}
  </span>
</template>
