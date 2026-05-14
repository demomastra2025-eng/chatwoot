<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
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
  emits: ['created', 'replaceText'],
  data() {
    return {
      amountInput: '',
      showAmountForm: false,
      showDropdown: false,
      isCreatingPayment: false,
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
    paymentMenuItems() {
      const items = [];

      if (this.hasKaspiPay) {
        items.push({
          icon: 'i-ph-qr-code',
          label: this.$t('CONVERSATION.REPLYBOX.PAYMENTS.KASPI_QR_LINK'),
          action: 'kaspi_qr_link',
          value: 'kaspi_qr_link',
        });
      }

      items.push({
        icon: 'i-ph-file-text',
        label: this.$t('CONVERSATION.REPLYBOX.PAYMENTS.INVOICE_SOON'),
        action: 'invoice',
        value: 'invoice',
        disabled: true,
      });

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
      if (action !== 'kaspi_qr_link') return;

      if (this.shouldPromptForAmount) {
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
      this.showAmountForm = true;
      this.$nextTick(() => this.$refs.amountInput?.focus());
    },
    normalizeAmount(value) {
      return Number(String(value || '').replace(/\s/g, ''));
    },
    paymentRequestPayload(amount) {
      const payload = {
        amount,
        ...(this.appointmentId ? { appointment_id: this.appointmentId } : {}),
        ...(this.conversationId
          ? { conversation_id: this.conversationId }
          : {}),
      };

      if (this.conversationId) {
        payload.idempotency_key = this.dialogPaymentIdempotencyKey(amount);
      }

      return payload;
    },
    dialogPaymentIdempotencyKey(amount) {
      const randomPart = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
      return `kaspi-pay:conversation:${this.conversationId}:${amount}:qr:${randomPart}`;
    },
    paymentText(payment, amount) {
      return this.$t('CONVERSATION.REPLYBOX.PAYMENTS.KASPI_PAYMENT_TEXT', {
        amount,
        currency: payment.currency || 'KZT',
        link: payment.qr_token || payment.receipt_url,
      });
    },
    async deliverPaymentText(paymentText, payment) {
      if (this.deliveryMode === 'copy') {
        await copyTextToClipboard(paymentText);
        useAlert(this.$t('CONVERSATION.REPLYBOX.PAYMENTS.CREATED_COPY'));
      } else {
        this.$emit('replaceText', paymentText);
        useAlert(this.$t('CONVERSATION.REPLYBOX.PAYMENTS.CREATED'));
      }
      this.$emit('created', { payment, text: paymentText });
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
        const paymentText = this.paymentText(payment, normalizedAmount);
        await this.deliverPaymentText(paymentText, payment);
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
        icon="i-ph-coins"
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
        @action="handlePaymentAction"
      />
      <form
        v-if="showAmountForm"
        class="absolute bottom-full ltr:left-0 rtl:right-0 mb-1 z-50 w-64 rounded-xl bg-n-alpha-3 p-3 shadow-lg outline outline-1 outline-n-container backdrop-blur-[100px]"
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
            :label="$t('CONVERSATION.REPLYBOX.PAYMENTS.CREATE_LINK')"
          />
        </div>
      </form>
    </template>
  </div>
</template>
