<script setup>
import { computed, getCurrentInstance, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  AsYouType,
  getCountryCallingCode,
  isValidPhoneNumber,
  parsePhoneNumberFromString,
} from 'libphonenumber-js';

import countries from 'shared/constants/countries.js';
import { getActiveCountryCode } from 'shared/components/PhoneInput/helper';

const props = defineProps({
  placeholder: {
    type: String,
    default: '',
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  showBorder: {
    type: Boolean,
    default: true,
  },
  showCountryFlag: {
    type: Boolean,
    default: true,
  },
  defaultCountry: {
    type: String,
    default: '',
  },
  label: {
    type: String,
    default: '',
  },
  size: {
    type: String,
    default: 'sm',
    validator: value => ['sm', 'md'].includes(value),
  },
  maxDigits: {
    type: Number,
    default: null,
  },
});

const emit = defineEmits(['blur']);
const modelValue = defineModel({
  type: [String, Number],
  default: '',
});

const { t } = useI18n();
const { uid } = getCurrentInstance();

const countryCodeToFlag = countryCode => {
  if (!countryCode || countryCode.length !== 2) return '🌐';

  return [...countryCode.toUpperCase()]
    .map(letter => String.fromCodePoint(letter.charCodeAt(0) + 127397))
    .join('');
};

const normalizeCountryCode = value => {
  const nextValue = String(value || '').toUpperCase();
  return countries.some(country => country.id === nextValue) ? nextValue : '';
};

const resolveFallbackCountry = () =>
  normalizeCountryCode(props.defaultCountry) ||
  normalizeCountryCode(getActiveCountryCode()) ||
  'KZ';

const inputId = computed(() => `phone-number-input-${uid}`);
const touched = ref(false);
const localInputValue = ref('');
const selectedCountryCode = ref(resolveFallbackCountry());

const hasError = computed(() => {
  if (!touched.value || !localInputValue.value) return false;
  if (!selectedCountryCode.value) return true;

  return !isValidPhoneNumber(
    String(modelValue.value || ''),
    selectedCountryCode.value
  );
});

const sizeClass = computed(() => (props.size === 'md' ? 'h-10' : 'h-8'));

const controlOutlineClass = computed(() => {
  if (props.disabled) {
    return 'outline-n-weak opacity-50';
  }

  if (hasError.value) {
    return 'outline-n-ruby-8 hover:outline-n-ruby-9 focus-within:outline-n-ruby-9';
  }

  if (!props.showBorder) {
    return 'outline-transparent hover:outline-transparent focus-within:outline-n-brand';
  }

  return 'outline-n-weak hover:outline-n-slate-6 focus-within:outline-n-brand';
});

const selectSurfaceClass = computed(() => [
  'relative inline-flex shrink-0 items-center gap-1.5 rounded-l-lg bg-n-alpha-black2 pl-3 pr-2 text-n-slate-12 outline outline-1 outline-offset-[-1px] transition-all duration-150 dark:bg-n-solid-1',
  sizeClass.value,
  controlOutlineClass.value,
]);

const inputSurfaceClass = computed(() => [
  'reset-base no-margin -ml-px block min-w-0 flex-1 rounded-r-lg rounded-l-none border-0 bg-n-alpha-black2 px-3 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] transition-all duration-150 placeholder:text-n-slate-10 dark:bg-n-solid-1',
  sizeClass.value,
  controlOutlineClass.value,
]);

const orderedCountries = computed(() => countries);

const currentDialCode = computed(() => {
  const countryCode = selectedCountryCode.value || resolveFallbackCountry();
  if (!countryCode) return '';

  return `+${getCountryCallingCode(countryCode)}`;
});

const errorMessage = computed(() => {
  if (!touched.value || !localInputValue.value) return '';
  if (!selectedCountryCode.value) return t('PHONE_INPUT.DIAL_CODE_ERROR');
  if (hasError.value) {
    return t('PHONE_INPUT.ERROR');
  }

  return '';
});

const normalizedMaxDigits = computed(() => {
  const parsedValue = Number(props.maxDigits);
  if (!Number.isFinite(parsedValue) || parsedValue <= 0) {
    return null;
  }

  return Math.floor(parsedValue);
});

const limitInputDigits = value => {
  const digits = String(value || '').replace(/\D/g, '');
  if (!normalizedMaxDigits.value) {
    return digits;
  }

  return digits.slice(0, normalizedMaxDigits.value);
};

const normalizeKzNationalDigits = value => {
  const digits = String(value || '').replace(/\D/g, '');

  if (!digits) return '';
  if (digits.length === 11 && ['7', '8'].includes(digits[0])) {
    return digits.slice(1);
  }

  return digits.slice(0, 10);
};

const formatKzNationalValue = value => {
  const digits = normalizeKzNationalDigits(value);
  if (!digits) return '';
  if (digits.length <= 3) return digits;
  if (digits.length <= 6) return `${digits.slice(0, 3)} ${digits.slice(3)}`;
  return `${digits.slice(0, 3)} ${digits.slice(3, 6)} ${digits.slice(6, 10)}`;
};

const formatNationalValue = (value, countryCode) => {
  const limitedDigits = limitInputDigits(value);
  if (!limitedDigits) return '';

  if (countryCode === 'KZ') {
    return formatKzNationalValue(limitedDigits);
  }

  const formatter = new AsYouType(countryCode);
  return formatter.input(limitedDigits);
};

const emitFormattedValue = nextValue => {
  if (!nextValue) {
    modelValue.value = '';
    return;
  }

  const countryCode = selectedCountryCode.value || resolveFallbackCountry();
  if (countryCode === 'KZ') {
    const digits = normalizeKzNationalDigits(nextValue);
    modelValue.value = digits ? `+7${digits}` : '';
    return;
  }

  const formatter = new AsYouType(countryCode);
  formatter.input(nextValue);

  const phoneNumber = formatter.getNumber();
  if (phoneNumber?.number) {
    modelValue.value = phoneNumber.number;
    return;
  }

  const digits = String(nextValue).replace(/\D/g, '');
  if (!digits) {
    modelValue.value = '';
    return;
  }

  modelValue.value = `+${getCountryCallingCode(countryCode)}${digits}`;
};

const syncFromModel = value => {
  const rawValue = String(value || '').trim();
  if (!rawValue) {
    localInputValue.value = '';
    selectedCountryCode.value = resolveFallbackCountry();
    return;
  }

  const parsed = parsePhoneNumberFromString(rawValue);
  if (parsed?.country) {
    selectedCountryCode.value = parsed.country;
    localInputValue.value = formatNationalValue(
      parsed.nationalNumber,
      parsed.country
    );
    return;
  }

  const fallbackCountry = selectedCountryCode.value || resolveFallbackCountry();
  const fallbackDialCode = getCountryCallingCode(fallbackCountry);
  const digits = rawValue.replace(/\D/g, '');
  const nationalDigits = digits.startsWith(fallbackDialCode)
    ? digits.slice(fallbackDialCode.length)
    : digits;

  selectedCountryCode.value = fallbackCountry;
  localInputValue.value = formatNationalValue(nationalDigits, fallbackCountry);
};

const handleCountryChange = event => {
  selectedCountryCode.value =
    normalizeCountryCode(event.target.value) || resolveFallbackCountry();
  localInputValue.value = formatNationalValue(
    localInputValue.value,
    selectedCountryCode.value
  );
  emitFormattedValue(localInputValue.value);
};

const handleInput = event => {
  localInputValue.value = formatNationalValue(
    event.target.value,
    selectedCountryCode.value || resolveFallbackCountry()
  );
  emitFormattedValue(localInputValue.value);
};

const handleBlur = () => {
  touched.value = true;
  emit('blur', modelValue.value);
};

watch(
  () => props.defaultCountry,
  nextValue => {
    if (!modelValue.value && normalizeCountryCode(nextValue)) {
      selectedCountryCode.value = normalizeCountryCode(nextValue);
    }
  }
);

watch(
  () => modelValue.value,
  nextValue => {
    syncFromModel(nextValue);
  },
  { immediate: true }
);
</script>

<template>
  <div class="flex min-w-0 flex-col gap-1" dir="ltr">
    <label
      v-if="label"
      :for="inputId"
      class="mb-0.5 text-sm font-medium text-n-slate-12"
    >
      {{ label }}
    </label>

    <div class="flex min-w-0 rounded-lg shadow-xs shadow-black/[.04]">
      <div :class="selectSurfaceClass">
        <span
          v-if="showCountryFlag"
          class="text-base leading-none"
          aria-hidden="true"
        >
          {{ countryCodeToFlag(selectedCountryCode) }}
        </span>
        <span
          class="shrink-0 whitespace-nowrap text-sm font-medium tabular-nums text-n-slate-11"
        >
          {{ currentDialCode }}
        </span>
        <span
          class="i-lucide-chevron-down size-3.5 shrink-0 text-n-slate-10"
          aria-hidden="true"
        />
        <select
          class="absolute inset-0 cursor-pointer opacity-0"
          :value="selectedCountryCode"
          :disabled="disabled"
          :aria-label="t('PHONE_INPUT.SEARCH_PLACEHOLDER')"
          @change="handleCountryChange"
        >
          <option
            v-for="country in orderedCountries"
            :key="country.id"
            :value="country.id"
          >
            {{ `${country.name} ${country.dial_code}` }}
          </option>
        </select>
      </div>

      <input
        :id="inputId"
        :value="localInputValue"
        type="tel"
        inputmode="tel"
        :disabled="disabled"
        :placeholder="placeholder"
        :class="inputSurfaceClass"
        @input="handleInput"
        @blur="handleBlur"
      />
    </div>

    <p
      v-if="errorMessage"
      class="mt-1 mb-0 min-w-0 truncate text-xs text-n-ruby-9 transition-all duration-150"
    >
      {{ errorMessage }}
    </p>
  </div>
</template>
