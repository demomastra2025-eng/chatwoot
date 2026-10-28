<script setup>
import { ref, computed, reactive } from 'vue';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength, email } from '@vuelidate/validators';
import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { DEFAULT_REDIRECT_URL } from 'dashboard/constants/globals';
import VueHcaptcha from '@hcaptcha/vue3-hcaptcha';
import FormInput from '../../../../../components/Form/Input.vue';
import CheckBox from '../../../../../components/Form/CheckBox.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import PasswordRequirements from './PasswordRequirements.vue';
import { isValidPassword } from 'shared/helpers/Validators';
import GoogleOAuthButton from '../../../../../components/GoogleOauth/Button.vue';
import { register } from '../../../../../api/auth';

const MIN_PASSWORD_LENGTH = 6;
const companySizes = [
  { value: '1-10', label: '1–10' },
  { value: '11-50', label: '11–50' },
  { value: '51-200', label: '51–200' },
  { value: '201-1000', label: '201–1000' },
  { value: '1000+', label: '1000+' },
];

const store = useStore();
const { t, locale } = useI18n();

const hCaptcha = ref(null);
const isPasswordFocused = ref(false);
const isSignupInProgress = ref(false);

const credentials = reactive({
  email: new URLSearchParams(window.location.search).get('email') || '',
  companyName: '',
  contactPhone: '',
  companySize: '',
  industry: '',
  industryOther: '',
  password: '',
  hCaptchaClientResponse: '',
});

const consent = reactive({
  terms: false,
  privacy: false,
});

const rules = {
  credentials: {
    companyName: { required, minLength: minLength(2) },
    industryOther: {
      requiredWhenOther: value =>
        credentials.industry !== 'other' || Boolean(value?.trim()),
    },
    email: {
      required,
      email,
    },
    password: {
      required,
      isValidPassword,
      minLength: minLength(MIN_PASSWORD_LENGTH),
    },
  },
  consent: {
    terms: {
      accepted: value => value === true,
    },
    privacy: {
      accepted: value => value === true,
    },
  },
};

const v$ = useVuelidate(rules, { credentials, consent });

const globalConfig = computed(() => store.getters['globalConfig/get']);

const allowedLoginMethods = computed(
  () => window.chatwootConfig.allowedLoginMethods || ['email']
);

const showGoogleOAuth = computed(
  () =>
    allowedLoginMethods.value.includes('google_oauth') &&
    Boolean(window.chatwootConfig.googleOAuthClientId) &&
    Boolean(window.chatwootConfig.googleOAuthCallbackUrl)
);

const selectedLocale = computed(() => locale.value || 'ru');
const termsUrl = computed(() => `/legal/${selectedLocale.value}/terms`);
const privacyUrl = computed(() => `/legal/${selectedLocale.value}/privacy`);

const isFormValid = computed(() => !v$.value.$invalid);

const performRegistration = async () => {
  isSignupInProgress.value = true;
  try {
    await register(credentials);
    window.location = DEFAULT_REDIRECT_URL;
  } catch (error) {
    const errorMessage = error?.message || t('REGISTER.API.ERROR_MESSAGE');
    if (globalConfig.value.hCaptchaSiteKey) {
      hCaptcha.value.reset();
      credentials.hCaptchaClientResponse = '';
    }
    useAlert(errorMessage);
  } finally {
    isSignupInProgress.value = false;
  }
};

const submit = () => {
  if (isSignupInProgress.value) return;
  v$.value.$touch();
  if (v$.value.$invalid) return;
  isSignupInProgress.value = true;
  if (globalConfig.value.hCaptchaSiteKey) {
    hCaptcha.value.execute();
  } else {
    performRegistration();
  }
};

const onRecaptchaVerified = token => {
  credentials.hCaptchaClientResponse = token;
  performRegistration();
};

const onCaptchaError = () => {
  isSignupInProgress.value = false;
  credentials.hCaptchaClientResponse = '';
  hCaptcha.value.reset();
};
</script>

<template>
  <div class="flex-1">
    <form class="space-y-3" @submit.prevent="submit">
      <FormInput
        v-model="credentials.companyName"
        name="company_name"
        :label="$t('REGISTER.COMPANY_NAME.LABEL')"
        :placeholder="$t('REGISTER.COMPANY_NAME.PLACEHOLDER')"
        :has-error="v$.credentials.companyName.$error"
        :error-message="$t('REGISTER.COMPANY_NAME.ERROR')"
        @blur="v$.credentials.companyName.$touch"
      />
      <FormInput
        v-model="credentials.contactPhone"
        type="tel"
        name="contact_phone"
        :label="$t('REGISTER.CONTACT_PHONE.LABEL')"
        :placeholder="$t('REGISTER.CONTACT_PHONE.PLACEHOLDER')"
      />
      <label class="block text-sm text-n-slate-12" for="company-size">{{
        $t('REGISTER.COMPANY_SIZE.LABEL')
      }}</label>
      <select
        id="company-size"
        v-model="credentials.companySize"
        class="w-full rounded-md border border-n-container bg-n-solid-2 px-3 py-2 text-n-slate-12"
      >
        <option value="">{{ $t('REGISTER.COMPANY_SIZE.SELECT') }}</option>
        <option
          v-for="size in companySizes"
          :key="size.value"
          :value="size.value"
        >
          {{ size.label }}
        </option>
      </select>
      <label class="block text-sm text-n-slate-12" for="industry">{{
        $t('REGISTER.INDUSTRY.LABEL')
      }}</label>
      <select
        id="industry"
        v-model="credentials.industry"
        class="w-full rounded-md border border-n-container bg-n-solid-2 px-3 py-2 text-n-slate-12"
      >
        <option value="">{{ $t('REGISTER.INDUSTRY.SELECT') }}</option>
        <option value="healthcare">
          {{ $t('REGISTER.INDUSTRY.HEALTHCARE') }}
        </option>
        <option value="retail">{{ $t('REGISTER.INDUSTRY.RETAIL') }}</option>
        <option value="education">
          {{ $t('REGISTER.INDUSTRY.EDUCATION') }}
        </option>
        <option value="services">{{ $t('REGISTER.INDUSTRY.SERVICES') }}</option>
        <option value="manufacturing">
          {{ $t('REGISTER.INDUSTRY.MANUFACTURING') }}
        </option>
        <option value="technology">
          {{ $t('REGISTER.INDUSTRY.TECHNOLOGY') }}
        </option>
        <option value="finance">{{ $t('REGISTER.INDUSTRY.FINANCE') }}</option>
        <option value="other">{{ $t('REGISTER.INDUSTRY.OTHER') }}</option>
      </select>
      <FormInput
        v-if="credentials.industry === 'other'"
        v-model="credentials.industryOther"
        name="industry_other"
        :label="$t('REGISTER.INDUSTRY_OTHER.LABEL')"
        :has-error="v$.credentials.industryOther.$error"
        :error-message="$t('REGISTER.INDUSTRY_OTHER.ERROR')"
        @blur="v$.credentials.industryOther.$touch"
      />
      <FormInput
        v-model="credentials.email"
        type="email"
        name="email_address"
        :class="{ error: v$.credentials.email.$error }"
        :label="$t('REGISTER.EMAIL.LABEL')"
        :placeholder="$t('REGISTER.EMAIL.PLACEHOLDER')"
        :has-error="v$.credentials.email.$error"
        :error-message="$t('REGISTER.EMAIL.ERROR')"
        @blur="v$.credentials.email.$touch"
      />
      <div class="relative">
        <FormInput
          v-model="credentials.password"
          type="password"
          name="password"
          :class="{ error: v$.credentials.password.$error }"
          :label="$t('LOGIN.PASSWORD.LABEL')"
          :placeholder="$t('SET_NEW_PASSWORD.PASSWORD.PLACEHOLDER')"
          :has-error="v$.credentials.password.$error"
          @focus="isPasswordFocused = true"
          @blur="
            isPasswordFocused = false;
            v$.credentials.password.$touch();
          "
        />
        <Transition
          enter-active-class="transition duration-200 ease-out origin-left"
          enter-from-class="opacity-0 scale-90 translate-x-1"
          enter-to-class="opacity-100 scale-100 translate-x-0"
          leave-active-class="transition duration-150 ease-in origin-left"
          leave-from-class="opacity-100 scale-100 translate-x-0"
          leave-to-class="opacity-0 scale-90 translate-x-1"
        >
          <PasswordRequirements
            v-if="isPasswordFocused"
            :password="credentials.password"
          />
        </Transition>
      </div>
      <VueHcaptcha
        v-if="globalConfig.hCaptchaSiteKey"
        ref="hCaptcha"
        size="invisible"
        :sitekey="globalConfig.hCaptchaSiteKey"
        @verify="onRecaptchaVerified"
        @error="onCaptchaError"
        @expired="onCaptchaError"
        @challenge-expired="onCaptchaError"
        @closed="onCaptchaError"
      />
      <div
        class="space-y-3 rounded-lg border border-n-container bg-n-brand-solid/5 p-4"
      >
        <label class="flex items-start gap-3 text-sm text-n-slate-12">
          <CheckBox
            :is-checked="consent.terms"
            value="terms"
            @update="(_, value) => (consent.terms = value)"
          />
          <span>
            {{ $t('REGISTER.CONSENTS.TERMS_PREFIX') }}
            <a
              :href="termsUrl"
              target="_blank"
              rel="noopener noreferrer"
              class="font-medium text-n-brand hover:text-n-brand"
            >
              {{ $t('REGISTER.CONSENTS.TERMS_LINK') }}
            </a>
          </span>
        </label>
        <p v-if="v$.consent.terms.$error" class="text-sm text-n-ruby-9">
          {{ $t('REGISTER.CONSENTS.TERMS_ERROR') }}
        </p>
        <label class="flex items-start gap-3 text-sm text-n-slate-12">
          <CheckBox
            :is-checked="consent.privacy"
            value="privacy"
            @update="(_, value) => (consent.privacy = value)"
          />
          <span>
            {{ $t('REGISTER.CONSENTS.PRIVACY_PREFIX') }}
            <a
              :href="privacyUrl"
              target="_blank"
              rel="noopener noreferrer"
              class="font-medium text-n-brand hover:text-n-brand"
            >
              {{ $t('REGISTER.CONSENTS.PRIVACY_LINK') }}
            </a>
          </span>
        </label>
        <p v-if="v$.consent.privacy.$error" class="text-sm text-n-ruby-9">
          {{ $t('REGISTER.CONSENTS.PRIVACY_ERROR') }}
        </p>
      </div>
      <NextButton
        lg
        type="submit"
        data-testid="submit_button"
        class="w-full font-medium"
        :label="$t('REGISTER.SUBMIT')"
        :disabled="isSignupInProgress || !isFormValid"
        :is-loading="isSignupInProgress"
      />
    </form>
    <GoogleOAuthButton v-if="showGoogleOAuth" class="mt-3">
      {{ $t('REGISTER.OAUTH.GOOGLE_SIGNUP') }}
    </GoogleOAuthButton>
  </div>
</template>
