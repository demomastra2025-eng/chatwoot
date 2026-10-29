<script setup>
import { ref, computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import NextButton from 'dashboard/components-next/button/Button.vue';
import KaspiPayModal from './KaspiPayModal.vue';

defineProps({
  conversationId: {
    type: [Number, String],
    default: null,
  },
  contactId: {
    type: [Number, String],
    default: null,
  },
  contactPhone: {
    type: String,
    default: '',
  },
});

const { t } = useI18n();
const store = useStore();
const modalRef = ref(null);

const kaspiIntegration = computed(() => {
  const getter = store?.getters?.['integrations/getIntegration'];
  return typeof getter === 'function' ? getter('kaspi_pay') : null;
});

const isConnected = computed(() => Boolean(kaspiIntegration.value?.enabled));

const autoSendDefault = computed(() => {
  const hook = kaspiIntegration.value?.hooks?.[0];
  return hook?.settings?.auto_send_link_to_chat ?? true;
});

onMounted(() => {
  const list = store?.getters?.['integrations/getAppIntegrations'];
  const uiFlags = store?.getters?.['integrations/getUIFlags'];
  if (
    Array.isArray(list) &&
    list.length === 0 &&
    !uiFlags?.isFetching &&
    typeof store?.dispatch === 'function'
  ) {
    store.dispatch('integrations/get');
  }
});

const openModal = () => {
  modalRef.value?.open({ paymentType: 'qr' });
};

const notifySidebar = payment => {
  if (typeof window !== 'undefined' && payment) {
    window.dispatchEvent(
      new CustomEvent('kaspi-pay:changed', { detail: payment })
    );
  }
};
</script>

<template>
  <div class="inline-flex">
    <div v-if="isConnected && conversationId" class="inline-flex">
      <NextButton
        v-tooltip.top-end="t('INTEGRATION_SETTINGS.KASPI_PAY.SIDEBAR.TITLE')"
        icon="i-lucide-qr-code"
        slate
        faded
        sm
        data-test="kaspi-composer-btn"
        @click="openModal"
      />
      <KaspiPayModal
        ref="modalRef"
        :conversation-id="conversationId"
        :contact-id="contactId"
        :default-phone="contactPhone"
        :auto-send-default="autoSendDefault"
        can-send-to-chat
        @created="notifySidebar"
        @updated="notifySidebar"
      />
    </div>
  </div>
</template>
