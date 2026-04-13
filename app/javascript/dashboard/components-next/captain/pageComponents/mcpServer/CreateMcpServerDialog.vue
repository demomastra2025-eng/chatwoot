<script setup>
import { ref, computed } from 'vue';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import McpServerForm from './McpServerForm.vue';

const props = defineProps({
  selectedServer: {
    type: Object,
    default: () => ({}),
  },
  type: {
    type: String,
    default: 'create',
  },
});

const emit = defineEmits(['close']);
const { t } = useI18n();
const store = useStore();
const dialogRef = ref(null);

const dialogTitle = computed(() =>
  props.type === 'edit'
    ? t('CAPTAIN.MCP_SERVERS.EDIT.TITLE')
    : t('CAPTAIN.MCP_SERVERS.CREATE.TITLE')
);
const successMessage = computed(() =>
  props.type === 'edit'
    ? t('CAPTAIN.MCP_SERVERS.EDIT.SUCCESS_MESSAGE')
    : t('CAPTAIN.MCP_SERVERS.CREATE.SUCCESS_MESSAGE')
);
const errorMessage = computed(() =>
  props.type === 'edit'
    ? t('CAPTAIN.MCP_SERVERS.EDIT.ERROR_MESSAGE')
    : t('CAPTAIN.MCP_SERVERS.CREATE.ERROR_MESSAGE')
);

const handleSubmit = async serverDetails => {
  try {
    if (props.type === 'edit') {
      await store.dispatch('captainMcpServers/update', {
        id: props.selectedServer.id,
        ...serverDetails,
      });
    } else {
      await store.dispatch('captainMcpServers/create', serverDetails);
    }
    useAlert(successMessage.value);
    dialogRef.value.close();
  } catch (error) {
    useAlert(parseAPIErrorResponse(error) || errorMessage.value);
  }
};

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="2xl"
    :render-on-open-only="false"
    :title="dialogTitle"
    :description="$t('CAPTAIN.MCP_SERVERS.FORM_DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    @close="emit('close')"
  >
    <McpServerForm
      :mode="type"
      :server="selectedServer"
      @submit="handleSubmit"
      @cancel="dialogRef.close()"
    />
    <template #footer />
  </Dialog>
</template>
