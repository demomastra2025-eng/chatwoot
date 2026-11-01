<script setup>
import { ref, computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import KaspiPayAPI from 'dashboard/api/integrations/kaspiPay';

import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const { t } = useI18n();
const store = useStore();
const KASPI_PAY_LOGO_URL = '/dashboard/images/integrations/kaspi_pay.png';

const isLoading = ref(true);
const status = ref({
  connected: false,
  session_status: 'disconnected',
  organizations: [],
  auto_send_link_to_chat: true,
});
const recentPayments = ref([]);

const showAuthForm = ref(false);
const authStep = ref('phone'); // 'phone' | 'otp'
const phoneNumber = ref('');
const otpCode = ref('');
const processId = ref('');
const maskedPhone = ref('');
const otpDescription = ref('');
const showAdvancedClient = ref(false);
const appVersion = ref('');
const appBuild = ref('');
const authError = ref('');

const isSendingOtp = ref(false);
const isVerifyingOtp = ref(false);
const isCheckingSession = ref(false);
const isSavingSettings = ref(false);
const isDisconnecting = ref(false);
const actionPaymentId = ref(null);

const disconnectDialogRef = ref(null);
const refundDialogRef = ref(null);
const refundTarget = ref(null);
const refundAmount = ref('');
const refundError = ref('');
const isRefunding = ref(false);

const formatTenge = value => `${Number(value || 0).toLocaleString('ru-RU')} ₸`;

const formatDateTime = iso => {
  if (!iso) return '—';
  try {
    return new Date(iso).toLocaleString('ru-RU', {
      day: '2-digit',
      month: '2-digit',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  } catch {
    return iso;
  }
};

const checklistSteps = computed(() => [
  t('INTEGRATION_SETTINGS.KASPI_PAY.CHECKLIST.STEP_1'),
  t('INTEGRATION_SETTINGS.KASPI_PAY.CHECKLIST.STEP_2'),
  t('INTEGRATION_SETTINGS.KASPI_PAY.CHECKLIST.STEP_3'),
  t('INTEGRATION_SETTINGS.KASPI_PAY.CHECKLIST.STEP_4'),
]);

const sessionBadge = computed(() => {
  const s = status.value.session_status;
  if (s === 'active') {
    return {
      text: t('INTEGRATION_SETTINGS.KASPI_PAY.SESSION.ACTIVE'),
      classes: 'bg-n-teal-3 text-n-teal-11 border-n-teal-6',
    };
  }
  if (s === 'reauth_required') {
    return {
      text: t('INTEGRATION_SETTINGS.KASPI_PAY.SESSION.REAUTH_REQUIRED'),
      classes: 'bg-n-ruby-3 text-n-ruby-11 border-n-ruby-6',
    };
  }
  if (s === 'degraded') {
    return {
      text: t('INTEGRATION_SETTINGS.KASPI_PAY.SESSION.DEGRADED'),
      classes: 'bg-n-amber-3 text-n-amber-11 border-n-amber-6',
    };
  }
  return {
    text: t('INTEGRATION_SETTINGS.KASPI_PAY.SESSION.DISCONNECTED'),
    classes: 'bg-n-alpha-2 text-n-slate-11 border-n-weak',
  };
});

const paymentStatusClass = st => {
  if (st === 'paid') return 'bg-n-teal-3 text-n-teal-11 border-n-teal-6';
  if (st === 'pending') return 'bg-n-amber-3 text-n-amber-11 border-n-amber-6';
  if (st === 'refunded' || st === 'partially_refunded')
    return 'bg-n-alpha-2 text-n-slate-11 border-n-weak';
  return 'bg-n-ruby-3 text-n-ruby-11 border-n-ruby-6';
};

const loadAll = async () => {
  isLoading.value = true;
  try {
    const [{ data: statusData }, { data: paymentsData }] = await Promise.all([
      KaspiPayAPI.getStatus(),
      KaspiPayAPI.getPayments({ limit: 20 }),
    ]);
    status.value = statusData;
    appVersion.value = statusData.app_version || '';
    appBuild.value = statusData.app_build || '';
    recentPayments.value = paymentsData.payload || [];
    showAuthForm.value = !statusData.connected;
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        t('INTEGRATION_SETTINGS.KASPI_PAY.LOAD_ERROR')
    );
  } finally {
    isLoading.value = false;
  }
};

const startReconnect = () => {
  authError.value = '';
  authStep.value = 'phone';
  otpCode.value = '';
  processId.value = '';
  showAuthForm.value = true;
};

const handleSendOtp = async () => {
  authError.value = '';
  if (!phoneNumber.value.trim()) {
    authError.value = t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.PHONE_REQUIRED');
    return;
  }

  isSendingOtp.value = true;
  try {
    const { data } = await KaspiPayAPI.sendOtp({
      phoneNumber: phoneNumber.value.trim(),
      appVersion: appVersion.value.trim() || undefined,
      appBuild: appBuild.value.trim() || undefined,
    });
    processId.value = data.process_id;
    maskedPhone.value = data.phone_masked;
    otpDescription.value = data.description || '';
    authStep.value = 'otp';
    useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.OTP_SENT_ALERT'));
  } catch (error) {
    authError.value =
      error?.response?.data?.error ||
      error?.message ||
      t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.SEND_OTP_ERROR');
  } finally {
    isSendingOtp.value = false;
  }
};

const handleVerifyOtp = async () => {
  authError.value = '';
  if (!otpCode.value.trim()) {
    authError.value = t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.OTP_REQUIRED');
    return;
  }

  isVerifyingOtp.value = true;
  try {
    const { data } = await KaspiPayAPI.verifyOtp({
      processId: processId.value,
      otp: otpCode.value.trim(),
    });
    status.value = data;
    showAuthForm.value = false;
    authStep.value = 'phone';
    otpCode.value = '';
    await store.dispatch('integrations/get');
    useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.CONNECTED_ALERT'));
  } catch (error) {
    authError.value =
      error?.response?.data?.error ||
      error?.message ||
      t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.VERIFY_OTP_ERROR');
  } finally {
    isVerifyingOtp.value = false;
  }
};

const handleCheckSession = async () => {
  isCheckingSession.value = true;
  try {
    const { data } = await KaspiPayAPI.checkSession();
    status.value = data;
    if (data.check?.active) {
      useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.SESSION.CHECK_OK'));
    } else {
      useAlert(
        data.check?.error ||
          t('INTEGRATION_SETTINGS.KASPI_PAY.SESSION.CHECK_FAILED')
      );
    }
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        t('INTEGRATION_SETTINGS.KASPI_PAY.SESSION.CHECK_FAILED')
    );
  } finally {
    isCheckingSession.value = false;
  }
};

const handleToggleAutoSend = async value => {
  isSavingSettings.value = true;
  try {
    const { data } = await KaspiPayAPI.updateSettings({
      auto_send_link_to_chat: value,
    });
    status.value = data;
    useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.SETTINGS_SAVED'));
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        t('INTEGRATION_SETTINGS.KASPI_PAY.SETTINGS_ERROR')
    );
  } finally {
    isSavingSettings.value = false;
  }
};

const handleProfileChange = async event => {
  const newProfileId = event.target.value;
  if (!newProfileId) return;
  isSavingSettings.value = true;
  try {
    const { data } = await KaspiPayAPI.updateSettings({
      profile_id: newProfileId,
    });
    status.value = data;
    useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.SETTINGS_SAVED'));
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        t('INTEGRATION_SETTINGS.KASPI_PAY.SETTINGS_ERROR')
    );
  } finally {
    isSavingSettings.value = false;
  }
};

const handleConfirmDisconnect = async () => {
  isDisconnecting.value = true;
  try {
    const { data } = await KaspiPayAPI.disconnect();
    status.value = data;
    showAuthForm.value = true;
    authStep.value = 'phone';
    disconnectDialogRef.value?.close();
    await store.dispatch('integrations/get');
    useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.DISCONNECT.SUCCESS'));
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        t('INTEGRATION_SETTINGS.KASPI_PAY.DISCONNECT.ERROR')
    );
  } finally {
    isDisconnecting.value = false;
  }
};

const handleRefreshPayment = async payment => {
  actionPaymentId.value = payment.id;
  try {
    const { data } = await KaspiPayAPI.refreshPayment(payment.id);
    recentPayments.value = recentPayments.value.map(item =>
      item.id === data.id ? data : item
    );
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        t('INTEGRATION_SETTINGS.KASPI_PAY.REFRESH_ERROR')
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
    recentPayments.value = recentPayments.value.map(item =>
      item.id === data.id ? data : item
    );
    refundDialogRef.value?.close();
    useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.REFUND.SUCCESS'));
  } catch (error) {
    refundError.value =
      error?.response?.data?.error ||
      t('INTEGRATION_SETTINGS.KASPI_PAY.REFUND.ERROR');
  } finally {
    isRefunding.value = false;
  }
};

onMounted(() => {
  loadAll();
});
</script>

<template>
  <SettingsLayout
    :is-loading="isLoading"
    :loading-message="t('INTEGRATION_SETTINGS.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="t('INTEGRATION_SETTINGS.KASPI_PAY.TITLE')"
        :description="t('INTEGRATION_SETTINGS.KASPI_PAY.DESCRIPTION')"
        :back-button-label="t('GENERAL_SETTINGS.BACK')"
        :back-button-url="{
          name: 'settings_applications',
          params: { accountId: $route.params.accountId },
        }"
        feature-name="integrations"
      />
    </template>

    <template #body>
      <div class="flex flex-col gap-6 pb-8">
        <!-- Connected Organization Card -->
        <div
          v-if="status.connected"
          data-test="kaspi-connected-card"
          class="flex flex-col gap-5 rounded-2xl border border-n-weak bg-n-solid-2 p-6 shadow-xs"
        >
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="flex items-center gap-3.5">
              <div
                class="flex h-12 w-12 shrink-0 items-center justify-center rounded-xl border border-n-weak bg-n-solid-1 p-2"
              >
                <img
                  :src="KASPI_PAY_LOGO_URL"
                  alt="Kaspi Pay"
                  class="max-h-full max-w-full rounded-md"
                />
              </div>
              <div>
                <div class="flex flex-wrap items-center gap-2.5">
                  <h3 class="text-base font-semibold text-n-slate-12">
                    {{
                      status.organization_name ||
                      t('INTEGRATION_SETTINGS.KASPI_PAY.TITLE')
                    }}
                  </h3>
                  <span
                    class="inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-medium"
                    :class="sessionBadge.classes"
                  >
                    {{ sessionBadge.text }}
                  </span>
                </div>
                <p class="mt-0.5 text-xs text-n-slate-11">
                  <span v-if="status.organization_bin">
                    {{ t('INTEGRATION_SETTINGS.KASPI_PAY.BIN_LABEL') }}:
                    {{ status.organization_bin }} ·
                  </span>
                  <span v-if="status.cashier_phone_masked">
                    {{ t('INTEGRATION_SETTINGS.KASPI_PAY.CASHIER_LABEL') }}:
                    {{ status.cashier_phone_masked }} ·
                  </span>
                  <span>
                    {{ t('INTEGRATION_SETTINGS.KASPI_PAY.VERIFIED_AT_LABEL') }}:
                    {{ formatDateTime(status.last_verified_at) }}
                  </span>
                </p>
              </div>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <Button
                size="sm"
                variant="faded"
                icon="i-lucide-activity"
                data-test="kaspi-check-session-btn"
                :is-loading="isCheckingSession"
                :label="t('INTEGRATION_SETTINGS.KASPI_PAY.CHECK_SESSION')"
                @click="handleCheckSession"
              />
              <Button
                size="sm"
                variant="faded"
                icon="i-lucide-smartphone"
                :label="t('INTEGRATION_SETTINGS.KASPI_PAY.RECONNECT')"
                @click="startReconnect"
              />
              <Button
                size="sm"
                variant="ghost"
                color="ruby"
                data-test="kaspi-disconnect-btn"
                :label="t('INTEGRATION_SETTINGS.KASPI_PAY.DISCONNECT.ACTION')"
                @click="disconnectDialogRef?.open()"
              />
            </div>
          </div>

          <div
            v-if="status.last_error"
            class="rounded-xl border border-n-ruby-6 bg-n-ruby-3 px-4 py-3 text-xs text-n-ruby-11"
          >
            {{ status.last_error }}
          </div>

          <div
            v-if="status.organizations && status.organizations.length > 1"
            class="flex flex-col gap-1.5 border-t border-n-weak pt-4"
          >
            <label class="text-xs font-medium text-n-slate-12">
              {{ t('INTEGRATION_SETTINGS.KASPI_PAY.BRANCH_LABEL') }}
            </label>
            <select
              :value="status.profile_id"
              :disabled="isSavingSettings"
              class="max-w-md rounded-xl border border-n-weak bg-n-solid-1 px-3 py-2 text-sm text-n-slate-12"
              @change="handleProfileChange"
            >
              <option
                v-for="org in status.organizations"
                :key="org.profile_id"
                :value="String(org.profile_id)"
              >
                {{ org.organization_name }} ({{ org.organization_bin }})
              </option>
            </select>
          </div>

          <div
            class="flex items-center justify-between gap-4 border-t border-n-weak pt-4"
          >
            <div>
              <p class="text-sm font-medium text-n-slate-12">
                {{ t('INTEGRATION_SETTINGS.KASPI_PAY.AUTO_SEND_TITLE') }}
              </p>
              <p class="text-xs text-n-slate-11">
                {{ t('INTEGRATION_SETTINGS.KASPI_PAY.AUTO_SEND_HINT') }}
              </p>
            </div>
            <Switch
              :model-value="status.auto_send_link_to_chat"
              :disabled="isSavingSettings"
              @update:model-value="handleToggleAutoSend"
            />
          </div>
        </div>

        <!-- Cashier Onboarding Checklist & 2-Step SMS Form -->
        <div
          v-if="showAuthForm"
          data-test="kaspi-auth-card"
          class="grid grid-cols-1 gap-6 lg:grid-cols-2"
        >
          <div
            class="flex flex-col gap-4 rounded-2xl border border-n-weak bg-n-solid-2 p-6"
          >
            <h3 class="text-base font-semibold text-n-slate-12">
              {{ t('INTEGRATION_SETTINGS.KASPI_PAY.CHECKLIST.TITLE') }}
            </h3>
            <p class="text-xs leading-relaxed text-n-slate-11">
              {{ t('INTEGRATION_SETTINGS.KASPI_PAY.CHECKLIST.SUBTITLE') }}
            </p>
            <ol
              class="flex flex-col gap-3 text-xs leading-relaxed text-n-slate-12"
            >
              <li
                v-for="(stepText, idx) in checklistSteps"
                :key="idx"
                class="flex gap-2.5"
              >
                <span
                  class="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-n-alpha-2 text-[11px] font-semibold"
                >
                  {{ idx + 1 }}
                </span>
                <span>{{ stepText }}</span>
              </li>
            </ol>
          </div>

          <div
            class="flex flex-col justify-between gap-4 rounded-2xl border border-n-weak bg-n-solid-2 p-6"
          >
            <div v-if="authStep === 'phone'" class="flex flex-col gap-4">
              <h3 class="text-base font-semibold text-n-slate-12">
                {{ t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.STEP_PHONE_TITLE') }}
              </h3>

              <Input
                v-model="phoneNumber"
                type="tel"
                data-test="kaspi-cashier-phone-input"
                :label="t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.PHONE_LABEL')"
                :placeholder="
                  t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.PHONE_PLACEHOLDER')
                "
                :message="t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.PHONE_HINT')"
              />

              <div>
                <button
                  type="button"
                  class="text-xs font-medium text-n-slate-11 underline hover:text-n-slate-12"
                  @click="showAdvancedClient = !showAdvancedClient"
                >
                  {{ t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.ADVANCED_TOGGLE') }}
                </button>
                <div
                  v-if="showAdvancedClient"
                  class="mt-3 grid grid-cols-2 gap-3"
                >
                  <Input
                    v-model="appVersion"
                    type="text"
                    :label="
                      t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.APP_VERSION_LABEL')
                    "
                    placeholder="26.1029"
                  />
                  <Input
                    v-model="appBuild"
                    type="text"
                    :label="
                      t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.APP_BUILD_LABEL')
                    "
                    placeholder="1116"
                  />
                </div>
              </div>
            </div>

            <div v-else class="flex flex-col gap-4">
              <h3 class="text-base font-semibold text-n-slate-12">
                {{ t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.STEP_OTP_TITLE') }}
              </h3>
              <p class="text-xs text-n-slate-11">
                {{
                  otpDescription ||
                  t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.OTP_SENT_TO', {
                    phone: maskedPhone,
                  })
                }}
              </p>

              <Input
                v-model="otpCode"
                type="text"
                data-test="kaspi-otp-input"
                :label="t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.OTP_LABEL')"
                placeholder="1234"
              />
            </div>

            <div class="flex flex-col gap-3">
              <p
                v-if="authError"
                data-test="kaspi-auth-error"
                class="rounded-xl border border-n-ruby-6 bg-n-ruby-3 px-3.5 py-2.5 text-xs leading-relaxed text-n-ruby-11"
              >
                {{ authError }}
              </p>

              <div class="flex flex-wrap items-center gap-2">
                <Button
                  v-if="authStep === 'phone'"
                  variant="solid"
                  data-test="kaspi-send-otp-btn"
                  :is-loading="isSendingOtp"
                  :label="t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.SEND_OTP_BTN')"
                  @click="handleSendOtp"
                />
                <template v-else>
                  <Button
                    variant="solid"
                    data-test="kaspi-verify-otp-btn"
                    :is-loading="isVerifyingOtp"
                    :label="
                      t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.VERIFY_OTP_BTN')
                    "
                    @click="handleVerifyOtp"
                  />
                  <Button
                    variant="faded"
                    :label="
                      t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.CHANGE_PHONE_BTN')
                    "
                    @click="authStep = 'phone'"
                  />
                </template>
                <Button
                  v-if="status.connected"
                  variant="ghost"
                  :label="t('INTEGRATION_SETTINGS.KASPI_PAY.AUTH.CANCEL_BTN')"
                  @click="showAuthForm = false"
                />
              </div>
            </div>
          </div>
        </div>

        <!-- Recent Payments Table -->
        <div
          v-if="recentPayments.length > 0"
          class="flex flex-col gap-3 rounded-2xl border border-n-weak bg-n-solid-2 p-6"
        >
          <h3 class="text-base font-semibold text-n-slate-12">
            {{ t('INTEGRATION_SETTINGS.KASPI_PAY.HISTORY.TITLE') }}
          </h3>

          <div class="overflow-x-auto">
            <table class="w-full text-left text-xs">
              <thead>
                <tr class="border-b border-n-weak text-n-slate-10">
                  <th class="pb-2.5 pr-4 font-medium">
                    {{ t('INTEGRATION_SETTINGS.KASPI_PAY.HISTORY.COL_DATE') }}
                  </th>
                  <th class="pb-2.5 pr-4 font-medium">
                    {{ t('INTEGRATION_SETTINGS.KASPI_PAY.HISTORY.COL_TYPE') }}
                  </th>
                  <th class="pb-2.5 pr-4 font-medium">
                    {{ t('INTEGRATION_SETTINGS.KASPI_PAY.HISTORY.COL_OP_ID') }}
                  </th>
                  <th class="pb-2.5 pr-4 font-medium">
                    {{ t('INTEGRATION_SETTINGS.KASPI_PAY.HISTORY.COL_AMOUNT') }}
                  </th>
                  <th class="pb-2.5 pr-4 font-medium">
                    {{ t('INTEGRATION_SETTINGS.KASPI_PAY.HISTORY.COL_STATUS') }}
                  </th>
                  <th class="pb-2.5 text-right font-medium">
                    {{
                      t('INTEGRATION_SETTINGS.KASPI_PAY.HISTORY.COL_ACTIONS')
                    }}
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-n-weak">
                <tr v-for="item in recentPayments" :key="item.id">
                  <td class="py-3 pr-4 text-n-slate-11">
                    {{ formatDateTime(item.created_at) }}
                  </td>
                  <td class="py-3 pr-4 text-n-slate-12">
                    {{
                      item.payment_type === 'qr'
                        ? t('INTEGRATION_SETTINGS.KASPI_PAY.TYPE.QR')
                        : t('INTEGRATION_SETTINGS.KASPI_PAY.TYPE.INVOICE')
                    }}
                  </td>
                  <td class="py-3 pr-4 font-mono text-n-slate-11">
                    #{{ item.qr_operation_id }}
                  </td>
                  <td class="py-3 pr-4 font-semibold text-n-slate-12">
                    {{ formatTenge(item.amount) }}
                  </td>
                  <td class="py-3 pr-4">
                    <span
                      class="inline-flex items-center rounded-full border px-2.5 py-0.5 text-[11px] font-medium"
                      :class="paymentStatusClass(item.status)"
                    >
                      {{
                        t(
                          `INTEGRATION_SETTINGS.KASPI_PAY.STATUS.${item.status.toUpperCase()}`
                        )
                      }}
                    </span>
                  </td>
                  <td class="py-3 text-right">
                    <div class="inline-flex items-center gap-1.5">
                      <Button
                        v-if="
                          ['pending', 'expired', 'lost', 'cancelled'].includes(
                            item.status
                          ) && !item.paid_at
                        "
                        size="xs"
                        variant="faded"
                        :is-loading="actionPaymentId === item.id"
                        :label="t('INTEGRATION_SETTINGS.KASPI_PAY.REFRESH')"
                        @click="handleRefreshPayment(item)"
                      />
                      <Button
                        v-if="item.refundable_amount > 0"
                        size="xs"
                        variant="faded"
                        color="ruby"
                        :label="
                          t('INTEGRATION_SETTINGS.KASPI_PAY.REFUND.ACTION')
                        "
                        @click="openRefundDialog(item)"
                      />
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <Dialog
          ref="disconnectDialogRef"
          type="alert"
          :title="t('INTEGRATION_SETTINGS.KASPI_PAY.DISCONNECT.TITLE')"
          :description="t('INTEGRATION_SETTINGS.KASPI_PAY.DISCONNECT.MESSAGE')"
          :is-loading="isDisconnecting"
          :confirm-button-label="
            t('INTEGRATION_SETTINGS.KASPI_PAY.DISCONNECT.CONFIRM')
          "
          @confirm="handleConfirmDisconnect"
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
    </template>
  </SettingsLayout>
</template>
