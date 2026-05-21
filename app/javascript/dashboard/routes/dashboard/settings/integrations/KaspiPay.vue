<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useFunctionGetter, useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import integrationAPI, {
  normalizeKaspiPayCashierPhone,
} from 'dashboard/api/integrations';
import Integration from './Integration.vue';
import Spinner from 'shared/components/Spinner.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const store = useStore();
const { t } = useI18n();
const integrationLoaded = ref(false);
const isSubmitting = ref(false);
const step = ref('phone');
const processId = ref('');
const phoneNumber = ref('');
const otp = ref('');
const formError = ref('');
const latitude = ref('43.238949');
const longitude = ref('76.889709');
const integration = useFunctionGetter(
  'integrations/getIntegration',
  'kaspi_pay'
);

const integrationAction = computed(() =>
  integration.value.enabled ? 'disconnect' : 'connect'
);

const hookMetadata = computed(
  () => integration.value.hooks?.[0]?.metadata || {}
);

const connectButtonLabel = computed(() => {
  if (isSubmitting.value) return '...';
  return step.value === 'phone'
    ? t('INTEGRATION_SETTINGS.KASPI_PAY.SEND_OTP')
    : t('INTEGRATION_SETTINGS.KASPI_PAY.CONNECT');
});

const KASPI_CASHIER_PHONE_PATTERN = /^7\d{9}$/;

const cashierPhoneDigits = computed(() =>
  normalizeKaspiPayCashierPhone(phoneNumber.value)
);

const isCashierPhoneComplete = computed(() =>
  KASPI_CASHIER_PHONE_PATTERN.test(cashierPhoneDigits.value)
);

const connectButtonDisabled = computed(() => {
  if (isSubmitting.value) return true;
  if (step.value === 'phone') return !isCashierPhoneComplete.value;
  return !otp.value;
});

const normalizePhoneInput = event => {
  phoneNumber.value = normalizeKaspiPayCashierPhone(event.target.value).slice(
    0,
    10
  );
};

const initializeKaspiPayIntegration = async () => {
  await store.dispatch('integrations/get', 'kaspi_pay');
  integrationLoaded.value = true;
};

const sendOtp = async () => {
  if (!isCashierPhoneComplete.value) {
    formError.value = t('INTEGRATION_SETTINGS.KASPI_PAY.PHONE_REQUIRED');
    return;
  }

  isSubmitting.value = true;
  formError.value = '';
  try {
    const initResponse = await integrationAPI.initKaspiPayAuth();
    processId.value = initResponse.data.process_id;
    const phoneResponse = await integrationAPI.sendKaspiPayPhone({
      processId: processId.value,
      phoneNumber: cashierPhoneDigits.value,
    });

    if (!phoneResponse.data.success) {
      formError.value =
        phoneResponse.data.description ||
        phoneResponse.data.error ||
        t('INTEGRATION_SETTINGS.KASPI_PAY.CONNECT_ERROR');
      return;
    }

    step.value = 'otp';
  } catch (error) {
    formError.value = t('INTEGRATION_SETTINGS.KASPI_PAY.CONNECT_ERROR');
  } finally {
    isSubmitting.value = false;
  }
};

const verifyOtp = async () => {
  if (!otp.value) {
    formError.value = t('INTEGRATION_SETTINGS.KASPI_PAY.OTP_REQUIRED');
    return;
  }

  isSubmitting.value = true;
  formError.value = '';
  try {
    await integrationAPI.verifyKaspiPayOtp({
      processId: processId.value,
      phoneNumber: cashierPhoneDigits.value,
      otp: otp.value,
      settings: {
        default_payment_type: 'qr',
        latitude: latitude.value,
        longitude: longitude.value,
      },
    });
    await initializeKaspiPayIntegration();
    useAlert(t('INTEGRATION_SETTINGS.KASPI_PAY.CONNECT_SUCCESS'));
  } catch (error) {
    formError.value = t('INTEGRATION_SETTINGS.KASPI_PAY.CONNECT_ERROR');
  } finally {
    isSubmitting.value = false;
  }
};

const submit = () => {
  if (step.value === 'phone') {
    sendOtp();
    return;
  }
  verifyOtp();
};

onMounted(() => {
  initializeKaspiPayIntegration();
});
</script>

<template>
  <div class="flex-grow flex-shrink p-4 overflow-auto max-w-6xl mx-auto">
    <div v-if="integrationLoaded" class="flex flex-col gap-6">
      <Integration
        :integration-id="integration.id"
        :integration-logo="integration.logo"
        :integration-name="integration.name"
        :integration-description="integration.description"
        :integration-enabled="integration.enabled"
        :integration-action="integrationAction"
        :delete-confirmation-text="{
          title: $t('INTEGRATION_SETTINGS.KASPI_PAY.DELETE.TITLE'),
          message: $t('INTEGRATION_SETTINGS.KASPI_PAY.DELETE.MESSAGE'),
        }"
      >
        <template #action>
          <Button
            teal
            :is-loading="isSubmitting"
            :disabled="connectButtonDisabled"
            :label="connectButtonLabel"
            @click="submit"
          />
        </template>
      </Integration>

      <div
        v-if="!integration.enabled"
        class="p-6 outline outline-n-container outline-1 bg-n-alpha-3 rounded-md shadow flex flex-col gap-4"
      >
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <Input
            v-model="phoneNumber"
            :label="$t('INTEGRATION_SETTINGS.KASPI_PAY.PHONE_LABEL')"
            placeholder="7012345678"
            type="tel"
            inputmode="numeric"
            pattern="[0-9]*"
            maxlength="16"
            :disabled="step === 'otp'"
            @input="normalizePhoneInput"
          />
          <Input
            v-if="step === 'otp'"
            v-model="otp"
            :label="$t('INTEGRATION_SETTINGS.KASPI_PAY.OTP_LABEL')"
            placeholder="1234"
          />
          <Input
            v-model="latitude"
            :label="$t('INTEGRATION_SETTINGS.KASPI_PAY.LATITUDE_LABEL')"
          />
          <Input
            v-model="longitude"
            :label="$t('INTEGRATION_SETTINGS.KASPI_PAY.LONGITUDE_LABEL')"
          />
        </div>
        <p class="text-sm text-n-slate-11">
          {{ $t('INTEGRATION_SETTINGS.KASPI_PAY.CONNECT_HELP') }}
        </p>
        <p v-if="formError" class="text-sm text-n-ruby-9">
          {{ formError }}
        </p>
      </div>

      <div
        v-else
        class="p-6 outline outline-n-container outline-1 bg-n-alpha-3 rounded-md shadow"
      >
        <h3 class="text-base font-medium text-n-slate-12 mb-2">
          {{ $t('INTEGRATION_SETTINGS.KASPI_PAY.CONNECTED_TITLE') }}
        </h3>
        <p class="text-sm text-n-slate-11">
          {{ hookMetadata.org_name || hookMetadata.organization_id || '-' }}
        </p>
        <p class="text-sm text-n-slate-11">
          {{ hookMetadata.phone_number || '-' }}
        </p>
      </div>
    </div>
    <div v-else class="flex items-center justify-center flex-1">
      <Spinner size="" color-scheme="primary" />
    </div>
  </div>
</template>
