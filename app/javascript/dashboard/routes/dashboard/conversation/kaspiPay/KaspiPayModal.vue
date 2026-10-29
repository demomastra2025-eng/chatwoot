<script setup>
import { ref, computed, watch, onBeforeUnmount } from 'vue';
import { useI18n } from 'vue-i18n';
import QRCode from 'qrcode';
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
import KaspiPayAPI from 'dashboard/api/integrations/kaspiPay';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const props = defineProps({
  conversationId: {
    type: [Number, String],
    default: null,
  },
  contactId: {
    type: [Number, String],
    default: null,
  },
  appointmentId: {
    type: [Number, String],
    default: null,
  },
  defaultPhone: {
    type: String,
    default: '',
  },
  defaultAmount: {
    type: [Number, String],
    default: '',
  },
  defaultComment: {
    type: String,
    default: '',
  },
  autoSendDefault: {
    type: Boolean,
    default: true,
  },
  canSendToChat: {
    type: Boolean,
    default: true,
  },
});

const emit = defineEmits(['created', 'updated']);

const { t } = useI18n();
const dialogRef = ref(null);

const paymentType = ref('qr');
const amount = ref('');
const payerPhone = ref('');
const comment = ref('');
const sendToConversation = ref(true);
const errorMessage = ref('');
const isSubmitting = ref(false);

const createdPayment = ref(null);
const qrDataUrl = ref('');
let pollTimer = null;
let pollInFlight = false;

const stopModalPolling = () => {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
  pollInFlight = false;
};

const formatTenge = value => {
  const num = Number(value || 0);
  return `${num.toLocaleString('ru-RU')} ₸`;
};

const resetForm = (overrides = {}) => {
  stopModalPolling();
  paymentType.value = overrides.paymentType || 'qr';
  amount.value =
    overrides.amount !== undefined && overrides.amount !== null
      ? String(overrides.amount)
      : String(props.defaultAmount || '');
  payerPhone.value = overrides.phone ?? props.defaultPhone ?? '';
  comment.value = overrides.comment ?? props.defaultComment ?? '';
  sendToConversation.value = props.canSendToChat && props.autoSendDefault;
  errorMessage.value = '';
  isSubmitting.value = false;
  createdPayment.value = null;
  qrDataUrl.value = '';
};

const renderQrImage = async url => {
  if (!url) {
    qrDataUrl.value = '';
    return;
  }
  try {
    const svg = await QRCode.toString(url, {
      type: 'svg',
      width: 220,
      margin: 1,
      errorCorrectionLevel: 'M',
    });
    qrDataUrl.value = `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`;
  } catch {
    qrDataUrl.value = '';
  }
};

const startModalPolling = paymentId => {
  stopModalPolling();
  pollTimer = setInterval(async () => {
    if (
      pollInFlight ||
      !createdPayment.value ||
      createdPayment.value.id !== paymentId ||
      createdPayment.value.status !== 'pending'
    ) {
      if (!createdPayment.value || createdPayment.value.status !== 'pending') {
        stopModalPolling();
      }
      return;
    }
    pollInFlight = true;
    try {
      const { data } = await KaspiPayAPI.getPayment(paymentId);
      if (createdPayment.value?.id !== paymentId) return;
      createdPayment.value = data;
      emit('updated', data);
      if (data.status !== 'pending') {
        stopModalPolling();
      }
    } catch {
      // Background Sidekiq job continues polling even on transient UI error
    } finally {
      pollInFlight = false;
    }
  }, 4000);
};

const open = (overrides = {}) => {
  resetForm(overrides);
  dialogRef.value?.open();
};

const close = () => {
  stopModalPolling();
  dialogRef.value?.close();
};

const isFormValid = computed(() => {
  const parsedAmount = Number(amount.value);
  if (!Number.isFinite(parsedAmount) || Math.round(parsedAmount) <= 0)
    return false;
  if (paymentType.value === 'invoice' && !payerPhone.value.trim()) return false;
  return true;
});

const statusBadgeClass = computed(() => {
  const st = createdPayment.value?.status;
  if (st === 'paid') return 'bg-n-teal-3 text-n-teal-11 border-n-teal-6';
  if (st === 'pending') return 'bg-n-amber-3 text-n-amber-11 border-n-amber-6';
  return 'bg-n-ruby-3 text-n-ruby-11 border-n-ruby-6';
});

const handleSubmit = async () => {
  if (createdPayment.value) {
    close();
    return;
  }

  errorMessage.value = '';
  const parsedAmount = Math.round(Number(amount.value));
  if (!parsedAmount || parsedAmount <= 0) {
    errorMessage.value = t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.AMOUNT_ERROR');
    return;
  }

  if (paymentType.value === 'invoice' && !payerPhone.value.trim()) {
    errorMessage.value = t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.PHONE_ERROR');
    return;
  }

  isSubmitting.value = true;
  try {
    const { data } = await KaspiPayAPI.createPayment({
      payment_type: paymentType.value,
      amount: parsedAmount,
      payer_phone:
        paymentType.value === 'invoice' ? payerPhone.value.trim() : undefined,
      comment: comment.value.trim() || undefined,
      conversation_id: props.conversationId || undefined,
      contact_id: props.contactId || undefined,
      appointment_id: props.appointmentId || undefined,
      send_to_conversation:
        paymentType.value === 'qr' &&
        props.canSendToChat &&
        sendToConversation.value,
    });

    emit('created', data);

    if (paymentType.value === 'qr') {
      createdPayment.value = data;
      await renderQrImage(data.unified_qr_url || data.pay_url);
      startModalPolling(data.id);
      useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.QR_CREATED_ALERT'));
    } else {
      useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.INVOICE_CREATED_ALERT'));
      close();
    }
  } catch (error) {
    errorMessage.value =
      error?.response?.data?.error ||
      error?.message ||
      t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.CREATE_ERROR');
  } finally {
    isSubmitting.value = false;
  }
};

const handleCopyLink = async () => {
  const link = createdPayment.value?.pay_url;
  if (!link) return;
  await copyTextToClipboard(link);
  useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.LINK_COPIED'));
};

watch(
  () => props.defaultPhone,
  val => {
    if (!payerPhone.value && val) payerPhone.value = val;
  }
);

onBeforeUnmount(() => {
  stopModalPolling();
});

defineExpose({ open, close });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="lg"
    :title="t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.TITLE')"
    :is-loading="isSubmitting"
    :show-cancel-button="!createdPayment"
    :confirm-button-label="
      createdPayment
        ? t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.DONE')
        : t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.SUBMIT')
    "
    :disable-confirm-button="!createdPayment && !isFormValid"
    @confirm="handleSubmit"
    @close="stopModalPolling"
  >
    <div v-if="createdPayment" class="flex flex-col items-center gap-4 py-2">
      <div class="flex items-center gap-2">
        <span
          class="inline-flex items-center rounded-full border px-3 py-1 text-xs font-medium"
          :class="statusBadgeClass"
        >
          {{
            t(
              `INTEGRATION_SETTINGS.KASPI_PAY.STATUS.${createdPayment.status.toUpperCase()}`
            )
          }}
        </span>
        <span class="text-base font-semibold text-n-slate-12">
          {{ formatTenge(createdPayment.amount) }}
        </span>
      </div>

      <div
        v-if="qrDataUrl"
        class="rounded-2xl border border-n-weak bg-white p-3 shadow-xs"
      >
        <img
          :src="qrDataUrl"
          alt="Kaspi QR"
          class="h-52 w-52 object-contain"
          data-test="kaspi-qr-image"
        />
      </div>

      <p class="text-center text-xs text-n-slate-11">
        {{ t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.UNIFIED_QR_HINT') }}
      </p>

      <div
        v-if="createdPayment.pay_url"
        class="flex w-full items-center justify-between gap-2 rounded-xl border border-n-weak bg-n-alpha-1 px-3 py-2"
      >
        <span class="truncate text-xs text-n-slate-11">
          {{ createdPayment.pay_url }}
        </span>
        <Button
          size="xs"
          variant="faded"
          icon="i-lucide-copy"
          :label="t('INTEGRATION_SETTINGS.KASPI_PAY.COPY_LINK')"
          @click="handleCopyLink"
        />
      </div>
    </div>

    <div v-else class="flex flex-col gap-4">
      <div
        class="grid grid-cols-2 gap-2 rounded-xl border border-n-weak bg-n-alpha-1 p-1"
      >
        <button
          type="button"
          data-test="kaspi-mode-qr"
          class="rounded-lg px-3 py-2 text-xs font-medium transition-colors"
          :class="
            paymentType === 'qr'
              ? 'bg-n-solid-3 text-n-slate-12 shadow-xs'
              : 'text-n-slate-11 hover:text-n-slate-12'
          "
          @click="paymentType = 'qr'"
        >
          {{ t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.MODE_QR') }}
        </button>
        <button
          type="button"
          data-test="kaspi-mode-invoice"
          class="rounded-lg px-3 py-2 text-xs font-medium transition-colors"
          :class="
            paymentType === 'invoice'
              ? 'bg-n-solid-3 text-n-slate-12 shadow-xs'
              : 'text-n-slate-11 hover:text-n-slate-12'
          "
          @click="paymentType = 'invoice'"
        >
          {{ t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.MODE_INVOICE') }}
        </button>
      </div>

      <Input
        v-model="amount"
        type="number"
        data-test="kaspi-amount-input"
        :label="t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.AMOUNT_LABEL')"
        :placeholder="
          t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.AMOUNT_PLACEHOLDER')
        "
      />

      <Input
        v-if="paymentType === 'invoice'"
        v-model="payerPhone"
        type="tel"
        data-test="kaspi-phone-input"
        :label="t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.PHONE_LABEL')"
        :placeholder="
          t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.PHONE_PLACEHOLDER')
        "
        :message="t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.PHONE_HINT')"
      />

      <Input
        v-model="comment"
        type="text"
        data-test="kaspi-comment-input"
        :label="t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.COMMENT_LABEL')"
        :placeholder="
          t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.COMMENT_PLACEHOLDER')
        "
      />

      <div
        v-if="paymentType === 'qr' && canSendToChat"
        class="flex items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-alpha-1 px-3.5 py-2.5"
      >
        <span class="text-xs text-n-slate-12">
          {{ t('INTEGRATION_SETTINGS.KASPI_PAY.MODAL.SEND_TO_CHAT_LABEL') }}
        </span>
        <Switch v-model="sendToConversation" />
      </div>

      <p
        v-if="errorMessage"
        data-test="kaspi-modal-error"
        class="rounded-lg border border-n-ruby-6 bg-n-ruby-3 px-3 py-2 text-xs text-n-ruby-11"
      >
        {{ errorMessage }}
      </p>
    </div>
  </Dialog>
</template>
