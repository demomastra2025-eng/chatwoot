<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
import QRCode from 'qrcode';
import NextButton from 'dashboard/components-next/button/Button.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import KaspiPayPaymentsAPI from 'dashboard/api/kaspiPayPayments';
import {
  getEnabledPaymentProviders,
  isKaspiPayEnabled,
} from 'dashboard/helper/paymentProviderHelper';

export default {
  name: 'PaymentActionButton',
  components: {
    DropdownMenu,
    NextButton,
  },
  props: {
    conversationId: {
      type: Number,
      default: 0,
    },
    appointmentId: {
      type: Number,
      default: 0,
    },
    defaultAmount: {
      type: [Number, String],
      default: 0,
    },
    deliveryMode: {
      type: String,
      default: 'composer',
      validator: value => ['composer', 'copy'].includes(value),
    },
    label: {
      type: String,
      default: '',
    },
    requireAmountInput: {
      type: Boolean,
      default: true,
    },
  },
  emits: ['created', 'replaceText', 'attachFile'],
  data() {
    return {
      amountInput: '',
      showAmountForm: false,
      showDropdown: false,
      isCreatingPayment: false,
      selectedPaymentAction: 'kaspi_qr_link',
      phoneNumberInput: '',
    };
  },
  computed: {
    ...mapGetters({ appIntegrations: 'integrations/getAppIntegrations' }),
    enabledPaymentProviders() {
      return getEnabledPaymentProviders(this.appIntegrations);
    },
    hasEnabledPaymentProvider() {
      return this.enabledPaymentProviders.length > 0;
    },
    hasKaspiPay() {
      return isKaspiPayEnabled(this.appIntegrations);
    },
    normalizedDefaultAmount() {
      const amount = this.normalizeAmount(this.defaultAmount);
      return Number.isInteger(amount) && amount > 0 ? amount : 0;
    },
    shouldPromptForAmount() {
      return this.requireAmountInput || !this.normalizedDefaultAmount;
    },
    paymentSubmitLabel() {
      if (this.selectedPaymentAction === 'kaspi_invoice') {
        return this.$t('CONVERSATION.REPLYBOX.PAYMENTS.CREATE_INVOICE');
      }
      if (this.selectedPaymentAction === 'kaspi_qr_image') {
        return this.$t('CONVERSATION.REPLYBOX.PAYMENTS.CREATE_QR_IMAGE');
      }

      return this.$t('CONVERSATION.REPLYBOX.PAYMENTS.CREATE_LINK');
    },
    paymentMenuItems() {
      const items = [];

      if (this.hasKaspiPay) {
        items.push(
          {
            icon: 'i-ph-link',
            label: this.$t('CONVERSATION.REPLYBOX.PAYMENTS.KASPI_QR_LINK'),
            action: 'kaspi_qr_link',
            value: 'kaspi_qr_link',
          },
          {
            icon: 'i-ph-qr-code',
            label: this.$t('CONVERSATION.REPLYBOX.PAYMENTS.KASPI_QR_IMAGE'),
            action: 'kaspi_qr_image',
            value: 'kaspi_qr_image',
          },
          {
            icon: 'i-ph-file-text',
            label: this.$t('CONVERSATION.REPLYBOX.PAYMENTS.KASPI_INVOICE'),
            action: 'kaspi_invoice',
            value: 'kaspi_invoice',
          }
        );
      }

      return items;
    },
  },
  mounted() {
    if (!(this.appIntegrations || []).length) {
      this.$store.dispatch('integrations/get');
    }
  },
  methods: {
    closePaymentMenus() {
      if (this.isCreatingPayment) return;
      this.showDropdown = false;
      this.showAmountForm = false;
    },
    toggleDropdown(value = !this.showDropdown) {
      if (this.isCreatingPayment) return;
      this.showDropdown = value;
      if (value) this.showAmountForm = false;
    },
    handlePaymentAction({ action }) {
      this.toggleDropdown(false);
      if (
        !['kaspi_qr_link', 'kaspi_qr_image', 'kaspi_invoice'].includes(action)
      )
        return;

      this.selectedPaymentAction = action;
      if (this.shouldPromptForAmount || action === 'kaspi_invoice') {
        this.openAmountForm();
      } else {
        this.amountInput = String(this.normalizedDefaultAmount);
        this.createKaspiPaymentLink();
      }
    },
    openAmountForm() {
      this.amountInput = this.normalizedDefaultAmount
        ? String(this.normalizedDefaultAmount)
        : '';
      this.phoneNumberInput = '';
      this.showAmountForm = true;
      this.$nextTick(() => this.$refs.amountInput?.focus());
    },
    normalizeAmount(value) {
      return Number(String(value || '').replace(/\s/g, ''));
    },
    paymentRequestPayload(amount) {
      const paymentType =
        this.selectedPaymentAction === 'kaspi_invoice' ? 'invoice' : 'qr';
      const payload = {
        amount,
        payment_type: paymentType,
        ...(this.appointmentId ? { appointment_id: this.appointmentId } : {}),
        ...(this.conversationId
          ? { conversation_id: this.conversationId }
          : {}),
      };

      if (
        this.selectedPaymentAction === 'kaspi_invoice' &&
        this.phoneNumberInput
      ) {
        payload.phone_number = this.phoneNumberInput;
      }

      if (this.conversationId) {
        payload.idempotency_key = this.dialogPaymentIdempotencyKey(
          amount,
          paymentType
        );
      }

      return payload;
    },
    dialogPaymentIdempotencyKey(amount, paymentType = 'qr') {
      const randomPart = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
      return `kaspi-pay:conversation:${this.conversationId}:${amount}:${paymentType}:${randomPart}`;
    },
    paymentText(payment, amount) {
      if (payment.payment_type === 'invoice') {
        return this.$t('CONVERSATION.REPLYBOX.PAYMENTS.KASPI_INVOICE_TEXT', {
          amount,
          currency: payment.currency || 'KZT',
          orderNumber: payment.kaspi_order_number || payment.kaspi_operation_id,
        });
      }

      return this.$t('CONVERSATION.REPLYBOX.PAYMENTS.KASPI_PAYMENT_TEXT', {
        amount,
        currency: payment.currency || 'KZT',
        link: payment.qr_token || payment.receipt_url,
      });
    },
    qrImageText(payment, amount) {
      return this.$t('CONVERSATION.REPLYBOX.PAYMENTS.KASPI_QR_IMAGE_TEXT', {
        amount,
        currency: payment.currency || 'KZT',
        link: payment.qr_token || payment.receipt_url,
      });
    },
    qrImageFile(imageDataUrl, payment) {
      const [, metadata = '', base64Data = ''] =
        imageDataUrl.match(/^data:([^;]+);base64,(.*)$/) || [];
      const mimeType = metadata || 'image/png';
      const binary = atob(base64Data);
      const bytes = Uint8Array.from(binary, char => char.charCodeAt(0));
      const fileName = `kaspi-qr-${payment.id || Date.now()}.png`;
      const file = new File([bytes], fileName, { type: mimeType });
      return {
        name: fileName,
        type: mimeType,
        size: file.size,
        file,
      };
    },
    async deliverPaymentText(paymentText, payment, attachment = null) {
      if (this.deliveryMode === 'copy') {
        await copyTextToClipboard(paymentText);
        useAlert(this.$t('CONVERSATION.REPLYBOX.PAYMENTS.CREATED_COPY'));
      } else {
        if (attachment) this.$emit('attachFile', attachment);
        this.$emit('replaceText', paymentText);
        useAlert(this.$t('CONVERSATION.REPLYBOX.PAYMENTS.CREATED'));
      }
      this.$emit('created', { payment, text: paymentText, attachment });
    },
    async createKaspiPaymentLink() {
      const normalizedAmount = this.normalizeAmount(this.amountInput);
      if (!Number.isInteger(normalizedAmount) || normalizedAmount <= 0) {
        useAlert(this.$t('CONVERSATION.REPLYBOX.PAYMENTS.INVALID_AMOUNT'));
        return;
      }

      this.isCreatingPayment = true;
      try {
        const response = await KaspiPayPaymentsAPI.create(
          this.paymentRequestPayload(normalizedAmount)
        );
        const payment = response.data;
        let paymentText = this.paymentText(payment, normalizedAmount);
        let attachment = null;
        if (
          this.selectedPaymentAction === 'kaspi_qr_image' &&
          payment.qr_token
        ) {
          const imageDataUrl = await QRCode.toDataURL(payment.qr_token, {
            margin: 1,
            width: 256,
          });
          payment.qr_image_data_url = imageDataUrl;
          attachment = this.qrImageFile(imageDataUrl, payment);
          paymentText = this.qrImageText(payment, normalizedAmount);
        }
        await this.deliverPaymentText(paymentText, payment, attachment);
        this.showAmountForm = false;
      } catch (error) {
        const message =
          error?.response?.data?.error ||
          this.$t('CONVERSATION.REPLYBOX.PAYMENTS.CREATE_ERROR');
        useAlert(message);
      } finally {
        this.isCreatingPayment = false;
      }
    },
  },
};
</script>

<template>
  <div v-on-clickaway="closePaymentMenus" class="relative flex items-center">
    <template v-if="hasEnabledPaymentProvider">
      <NextButton
        v-tooltip.top-end="$t('CONVERSATION.REPLYBOX.PAYMENTS.TOOLTIP')"
        icon="i-ph-invoice"
        slate
        faded
        sm
        :is-loading="isCreatingPayment"
        :label="label"
        @click="toggleDropdown()"
      />
      <DropdownMenu
        v-if="showDropdown"
        :menu-items="paymentMenuItems"
        class="bottom-full mb-1 ltr:left-0 rtl:right-0 min-w-[220px]"
        @click.stop
        @action="handlePaymentAction"
      />
      <form
        v-if="showAmountForm"
        class="absolute bottom-full ltr:left-0 rtl:right-0 mb-1 z-[160] w-64 rounded-xl bg-n-alpha-3 p-3 shadow-lg outline outline-1 outline-n-container backdrop-blur-[100px]"
        @click.stop
        @keydown.esc.prevent="closePaymentMenus"
        @submit.prevent="createKaspiPaymentLink"
      >
        <label class="mb-2 block text-xs font-medium text-n-slate-11">
          {{ $t('CONVERSATION.REPLYBOX.PAYMENTS.AMOUNT_LABEL') }}
        </label>
        <input
          ref="amountInput"
          v-model="amountInput"
          type="number"
          min="1"
          step="1"
          class="reset-base h-8 w-full rounded-lg border border-n-strong bg-n-solid-1 px-3 text-sm text-n-slate-12 focus:outline-none"
          :placeholder="$t('CONVERSATION.REPLYBOX.PAYMENTS.AMOUNT_PLACEHOLDER')"
        />
        <template v-if="selectedPaymentAction === 'kaspi_invoice'">
          <label class="mb-2 mt-3 block text-xs font-medium text-n-slate-11">
            {{ $t('CONVERSATION.REPLYBOX.PAYMENTS.PHONE_LABEL') }}
          </label>
          <input
            v-model="phoneNumberInput"
            type="tel"
            class="reset-base h-8 w-full rounded-lg border border-n-strong bg-n-solid-1 px-3 text-sm text-n-slate-12 focus:outline-none"
            :placeholder="
              $t('CONVERSATION.REPLYBOX.PAYMENTS.PHONE_PLACEHOLDER')
            "
          />
        </template>
        <div class="mt-3 flex justify-end gap-2">
          <NextButton
            type="button"
            slate
            faded
            xs
            :label="$t('CONVERSATION.REPLYBOX.PAYMENTS.CANCEL')"
            @click="closePaymentMenus"
          />
          <NextButton
            type="submit"
            blue
            xs
            :is-loading="isCreatingPayment"
            :label="paymentSubmitLabel"
          />
        </div>
      </form>
    </template>
  </div>
</template>
