<script setup>
import { computed, defineModel } from 'vue';
import { useI18n } from 'vue-i18n';
import Input from 'dashboard/components-next/input/Input.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';

defineProps({
  authType: {
    type: String,
    required: true,
    validator: value => ['none', 'bearer', 'basic', 'api_key'].includes(value),
  },
  errors: {
    type: Object,
    default: () => ({}),
  },
});

const { t } = useI18n();

const authConfig = defineModel('authConfig', {
  type: Object,
  default: () => ({}),
});

const apiKeyLocationOptions = computed(() => [
  {
    value: 'header',
    label: t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.API_KEY_LOCATIONS.HEADER'),
  },
  {
    value: 'query',
    label: t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.API_KEY_LOCATIONS.QUERY'),
  },
]);
</script>

<template>
  <div class="flex flex-col gap-2">
    <Input
      v-if="authType === 'bearer'"
      v-model="authConfig.token"
      :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.BEARER_TOKEN')"
      :placeholder="
        t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.BEARER_TOKEN_PLACEHOLDER')
      "
      :message="errors.token"
      :message-type="errors.token ? 'error' : 'info'"
    />
    <template v-else-if="authType === 'basic'">
      <Input
        v-model="authConfig.username"
        :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.USERNAME')"
        :placeholder="
          t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.USERNAME_PLACEHOLDER')
        "
        :message="errors.username"
        :message-type="errors.username ? 'error' : 'info'"
      />
      <Input
        v-model="authConfig.password"
        type="password"
        :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.PASSWORD')"
        :placeholder="
          t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.PASSWORD_PLACEHOLDER')
        "
        :message="errors.password"
        :message-type="errors.password ? 'error' : 'info'"
      />
    </template>
    <template v-else-if="authType === 'api_key'">
      <div class="flex flex-col gap-1">
        <label class="mb-0.5 text-sm font-medium text-n-slate-12">
          {{
            t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.API_KEY_LOCATION_LABEL')
          }}
        </label>
        <ComboBox
          v-model="authConfig.location"
          :options="apiKeyLocationOptions"
          :placeholder="
            t(
              'CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.API_KEY_LOCATION_PLACEHOLDER'
            )
          "
          class="[&>div>button]:bg-n-alpha-black2"
        />
      </div>
      <Input
        v-model="authConfig.name"
        :label="
          authConfig.location === 'query'
            ? t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.API_KEY_QUERY_NAME')
            : t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.API_KEY')
        "
        :placeholder="
          authConfig.location === 'query'
            ? t(
                'CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.API_KEY_QUERY_NAME_PLACEHOLDER'
              )
            : t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.API_KEY_PLACEHOLDER')
        "
        :message="errors.name"
        :message-type="errors.name ? 'error' : 'info'"
      />
      <Input
        v-model="authConfig.key"
        :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.API_VALUE')"
        :placeholder="
          t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_CONFIG.API_VALUE_PLACEHOLDER')
        "
        :message="errors.key"
        :message-type="errors.key ? 'error' : 'info'"
      />
    </template>
  </div>
</template>
