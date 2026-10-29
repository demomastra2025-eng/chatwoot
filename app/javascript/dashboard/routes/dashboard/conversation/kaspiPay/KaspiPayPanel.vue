<script setup>
import { ref, computed, watch, onMounted, onBeforeUnmount } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  useFunctionGetter,
  useMapGetter,
  useStore,
} from 'dashboard/composables/store';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { useAlert } from 'dashboard/composables';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
import KaspiPayAPI from 'dashboard/api/integrations/kaspiPay';

import AccordionItem from 'dashboard/components/Accordion/AccordionItem.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import KaspiPayModal from './KaspiPayModal.vue';

const props = defineProps({
  conversationId: {
    type: [Number, String],
    required: true,
  },
  contact: {
    type: Object,
    default: () => ({}),
  },
  selectedPatient: {
    type: Object,
    default: null,
  },
  isDraft: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();
const store = useStore();
const { isAdmin } = useAdmin();
const { isContactSidebarItemOpen, toggleSidebarUIState } = useUISettings();

const appIntegrations = useMapGetter('integrations/getAppIntegrations');
const kaspiIntegration = useFunctionGetter(
  'integrations/getIntegration',
  'kaspi_pay'
);

const payments = ref([]);
const meta = ref({
  connected: false,
  session_status: 'disconnected',
  auto_send_link_to_chat: true,
});
const isLoading = ref(false);
const actionPaymentId = ref(null);

const createModalRef = ref(null);
const refundDialogRef = ref(null);
const refundTarget = ref(null);
const refundAmount = ref('');
const refundError = ref('');
const isRefunding = ref(false);

let pollInterval = null;

const isConnected = computed(
  () =>
    Boolean(kaspiIntegration.value?.enabled) || Boolean(meta.value.connected)
);

const shouldRenderPanel = computed(
  () => !props.isDraft && (isConnected.value || payments.value.length > 0)
);

const defaultPhone = computed(
  () => props.selectedPatient?.phone_number || props.contact?.phone_number || ''
);

const activeContactId = computed(
  () => props.selectedPatient?.contact_id || props.contact?.id || null
);

const hasPendingPayments = computed(() =>
  payments.value.some(item => item.status === 'pending')
);

const stopLivePolling = () => {
  if (pollInterval) {
    clearInterval(pollInterval);
    pollInterval = null;
  }
};

const fetchPayments = async ({ silent = false } = {}) => {
  const targetConvId = props.conversationId;
  if (!targetConvId || props.isDraft) return;
  if (!silent) isLoading.value = true;
  try {
    const { data } = await KaspiPayAPI.getPayments({
      conversation_id: targetConvId,
      limit: 15,
    });
    if (String(props.conversationId) !== String(targetConvId)) return;
    meta.value = data.meta || meta.value;
    payments.value = data.payload || [];
  } catch {
    // Non-blocking in sidebar
  } finally {
    if (!silent && String(props.conversationId) === String(targetConvId)) {
      isLoading.value = false;
    }
  }
};

const syncLivePolling = () => {
  if (hasPendingPayments.value) {
    if (!pollInterval) {
      pollInterval = setInterval(() => {
        fetchPayments({ silent: true });
      }, 6000);
    }
  } else {
    stopLivePolling();
  }
};

watch(hasPendingPayments, () => {
  syncLivePolling();
});

watch(
  () => props.conversationId,
  newId => {
    stopLivePolling();
    payments.value = [];
    if (newId && !props.isDraft) {
      fetchPayments();
    }
  }
);

const handleExternalPaymentChange = async () => {
  await fetchPayments({ silent: true });
  syncLivePolling();
};

onMounted(async () => {
  window.addEventListener('kaspi-pay:changed', handleExternalPaymentChange);
  if (!appIntegrations.value?.length) {
    store.dispatch('integrations/get');
  }
  await fetchPayments();
  syncLivePolling();
});

onBeforeUnmount(() => {
  window.removeEventListener('kaspi-pay:changed', handleExternalPaymentChange);
  stopLivePolling();
});

const formatTenge = value => `${Number(value || 0).toLocaleString('ru-RU')} ₸`;

const statusClasses = status => {
  if (status === 'paid') return 'bg-n-teal-3 text-n-teal-11 border-n-teal-6';
  if (status === 'pending')
    return 'bg-n-amber-3 text-n-amber-11 border-n-amber-6';
  if (status === 'refunded' || status === 'partially_refunded')
    return 'bg-n-alpha-2 text-n-slate-11 border-n-weak';
  return 'bg-n-ruby-3 text-n-ruby-11 border-n-ruby-6';
};

const openCreateModal = (mode = 'qr') => {
  createModalRef.value?.open({ paymentType: mode });
};

const onPaymentCreated = payment => {
  payments.value = [
    payment,
    ...payments.value.filter(item => item.id !== payment.id),
  ];
  syncLivePolling();
};

const onPaymentUpdated = payment => {
  payments.value = payments.value.map(item =>
    item.id === payment.id ? payment : item
  );
  syncLivePolling();
};

const handleCopyLink = async payment => {
  if (!payment.pay_url) return;
  await copyTextToClipboard(payment.pay_url);
  useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.LINK_COPIED'));
};

const handleRefresh = async payment => {
  actionPaymentId.value = payment.id;
  try {
    const { data } = await KaspiPayAPI.refreshPayment(payment.id);
    onPaymentUpdated(data);
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        t('INTEGRATION_SETTINGS.KASPI_PAY.REFRESH_ERROR')
    );
  } finally {
    actionPaymentId.value = null;
  }
};

const handleCancel = async payment => {
  actionPaymentId.value = payment.id;
  try {
    const { data } = await KaspiPayAPI.cancelPayment(payment.id);
    onPaymentUpdated(data);
    useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.CANCEL_SUCCESS'));
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        t('INTEGRATION_SETTINGS.KASPI_PAY.CANCEL_ERROR')
    );
  } finally {
    actionPaymentId.value = null;
  }
};

const openRefundDialog = payment => {
  refundTarget.value = payment;
  refundAmount.value = String(
    payment.refundable_amount || payment.amount || ''
  );
  refundError.value = '';
  refundDialogRef.value?.open();
};

const handleConfirmRefund = async () => {
  if (!refundTarget.value) return;
  const parsed = Math.round(Number(refundAmount.value));
  if (!parsed || parsed <= 0 || parsed > refundTarget.value.refundable_amount) {
    refundError.value = t('INTEGRATION_SETTINGS.KASPI_PAY.REFUND.AMOUNT_ERROR');
    return;
  }

  isRefunding.value = true;
  refundError.value = '';
  try {
    const { data } = await KaspiPayAPI.refundPayment(refundTarget.value.id, {
      amount: parsed,
    });
    onPaymentUpdated(data);
    useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.REFUND.SUCCESS'));
    refundDialogRef.value?.close();
  } catch (error) {
    refundError.value =
      error?.response?.data?.error ||
      t('INTEGRATION_SETTINGS.KASPI_PAY.REFUND.ERROR');
  } finally {
    isRefunding.value = false;
  }
};
</script>

<template>
  <div>
    <div v-if="shouldRenderPanel" data-test="kaspi-pay-sidebar-panel">
      <AccordionItem
        :title="t('INTEGRATION_SETTINGS.KASPI_PAY.SIDEBAR.TITLE')"
        :is-open="isContactSidebarItemOpen('is_kaspi_pay_open')"
        icon="credit-card"
        compact
        @toggle="value => toggleSidebarUIState('is_kaspi_pay_open', value)"
      >
        <div class="flex flex-col gap-2.5 px-3 py-2">
          <div
            v-if="meta.session_status === 'reauth_required'"
            class="rounded-lg border border-n-ruby-6 bg-n-ruby-3 px-2.5 py-2 text-xs text-n-ruby-11"
          >
            {{ t('INTEGRATION_SETTINGS.KASPI_PAY.SIDEBAR.SESSION_EXPIRED') }}
          </div>

          <div v-if="isConnected" class="grid grid-cols-2 gap-1.5">
            <Button
              size="xs"
              variant="solid"
              icon="i-lucide-qr-code"
              data-test="kaspi-open-qr-btn"
              :label="t('INTEGRATION_SETTINGS.KASPI_PAY.SIDEBAR.CREATE_QR')"
              @click="openCreateModal('qr')"
            />
            <Button
              size="xs"
              variant="faded"
              icon="i-lucide-smartphone"
              data-test="kaspi-open-invoice-btn"
              :label="
                t('INTEGRATION_SETTINGS.KASPI_PAY.SIDEBAR.CREATE_INVOICE')
              "
              @click="openCreateModal('invoice')"
            />
          </div>

          <p
            v-if="!isLoading && payments.length === 0"
            class="py-2 text-center text-xs text-n-slate-10"
          >
            {{ t('INTEGRATION_SETTINGS.KASPI_PAY.SIDEBAR.EMPTY') }}
          </p>

          <div v-else class="flex flex-col gap-2">
            <div
              v-for="payment in payments"
              :key="payment.id"
              class="flex flex-col gap-1.5 rounded-xl border border-n-weak bg-n-solid-1 p-2.5"
            >
              <div class="flex items-center justify-between gap-2">
                <span class="text-sm font-semibold text-n-slate-12">
                  {{ formatTenge(payment.amount) }}
                </span>
                <span
                  class="inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] font-medium"
                  :class="statusClasses(payment.status)"
                >
                  {{
                    t(
                      `INTEGRATION_SETTINGS.KASPI_PAY.STATUS.${payment.status.toUpperCase()}`
                    )
                  }}
                </span>
              </div>

              <div
                class="flex items-center justify-between text-[11px] text-n-slate-10"
              >
                <span>
                  {{
                    payment.payment_type === 'qr'
                      ? t('INTEGRATION_SETTINGS.KASPI_PAY.TYPE.QR')
                      : t('INTEGRATION_SETTINGS.KASPI_PAY.TYPE.INVOICE')
                  }}
                  · #{{ payment.qr_operation_id }}
                </span>
                <span v-if="payment.payer_phone_masked">
                  {{ payment.payer_phone_masked }}
                </span>
              </div>

              <p
                v-if="payment.comment"
                class="line-clamp-1 text-xs text-n-slate-11"
              >
                {{ payment.comment }}
              </p>

              <div class="flex flex-wrap items-center gap-1.5 pt-1">
                <Button
                  v-if="payment.pay_url && payment.status === 'pending'"
                  size="xs"
                  variant="faded"
                  icon="i-lucide-copy"
                  :label="t('INTEGRATION_SETTINGS.KASPI_PAY.COPY_LINK')"
                  @click="handleCopyLink(payment)"
                />
                <Button
                  v-if="
                    ['pending', 'expired', 'lost', 'cancelled'].includes(
                      payment.status
                    ) && !payment.paid_at
                  "
                  size="xs"
                  variant="faded"
                  icon="i-lucide-refresh-cw"
                  :is-loading="actionPaymentId === payment.id"
                  :label="t('INTEGRATION_SETTINGS.KASPI_PAY.REFRESH')"
                  @click="handleRefresh(payment)"
                />
                <Button
                  v-if="
                    payment.status === 'pending' &&
                    payment.payment_type === 'invoice'
                  "
                  size="xs"
                  variant="ghost"
                  color="ruby"
                  :is-loading="actionPaymentId === payment.id"
                  :label="t('INTEGRATION_SETTINGS.KASPI_PAY.CANCEL')"
                  @click="handleCancel(payment)"
                />
                <Button
                  v-if="isAdmin && payment.refundable_amount > 0"
                  size="xs"
                  variant="faded"
                  color="ruby"
                  data-test="kaspi-refund-btn"
                  :label="t('INTEGRATION_SETTINGS.KASPI_PAY.REFUND.ACTION')"
                  @click="openRefundDialog(payment)"
                />
              </div>
            </div>
          </div>
        </div>
      </AccordionItem>

      <KaspiPayModal
        ref="createModalRef"
        :conversation-id="conversationId"
        :contact-id="activeContactId"
        :default-phone="defaultPhone"
        :auto-send-default="meta.auto_send_link_to_chat"
        :can-send-to-chat="!isDraft"
        @created="onPaymentCreated"
        @updated="onPaymentUpdated"
      />

      <Dialog
        ref="refundDialogRef"
        :title="t('INTEGRATION_SETTINGS.KASPI_PAY.REFUND.TITLE')"
        :is-loading="isRefunding"
        :confirm-button-label="
          t('INTEGRATION_SETTINGS.KASPI_PAY.REFUND.CONFIRM')
        "
        @confirm="handleConfirmRefund"
      >
        <div class="flex flex-col gap-3">
          <p class="text-xs text-n-slate-11">
            {{
              t('INTEGRATION_SETTINGS.KASPI_PAY.REFUND.DESCRIPTION', {
                maxAmount: formatTenge(refundTarget?.refundable_amount || 0),
              })
            }}
          </p>
          <Input
            v-model="refundAmount"
            type="number"
            :label="t('INTEGRATION_SETTINGS.KASPI_PAY.REFUND.AMOUNT_LABEL')"
          />
          <p
            v-if="refundError"
            class="rounded-lg border border-n-ruby-6 bg-n-ruby-3 px-3 py-2 text-xs text-n-ruby-11"
          >
            {{ refundError }}
          </p>
        </div>
      </Dialog>
    </div>
  </div>
</template>
