<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';

const props = defineProps({
  inbox: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['saved']);

const { t } = useI18n();
const store = useStore();

const isSaving = ref(false);
const saveError = ref('');

const form = reactive({
  mode: 'operator',
  appRef: '',
  aiAppRef: '',
  operatorAgentRef: '',
  operatorAgentAor: '',
  operatorDistributionMode: 'broadcast',
  fallbackMode: 'reject',
  fallbackMessage: '',
});

const telephony = computed(() => props.inbox?.telephony || {});
const routingPolicy = computed(() => telephony.value?.routing_policy || {});
const numberRef = computed(() => telephony.value?.number_ref || '');

const routeModeOptions = computed(() => [
  {
    value: 'operator',
    label: t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.OPERATOR'),
  },
  {
    value: 'ai',
    label: t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.AI'),
  },
  {
    value: 'app',
    label: t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.APP'),
  },
  {
    value: 'reject',
    label: t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.REJECT'),
  },
]);

const fallbackModeOptions = computed(() => [
  {
    value: 'reject',
    label: t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.REJECT'),
  },
  ...routeModeOptions.value.filter(option => option.value !== 'reject'),
]);

const operatorDistributionModeOptions = computed(() => [
  {
    value: 'broadcast',
    label: t('INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_DISTRIBUTION.BROADCAST'),
  },
  {
    value: 'targeted',
    label: t('INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_DISTRIBUTION.TARGETED'),
  },
]);

const trimValue = value => String(value || '').trim();
const hasOperatorTarget = computed(
  () => trimValue(form.operatorAgentRef) || trimValue(form.operatorAgentAor)
);
const isTargetedOperatorDistribution = computed(
  () => form.operatorDistributionMode === 'targeted'
);
const needsOperatorTarget = computed(
  () =>
    isTargetedOperatorDistribution.value &&
    (form.mode === 'operator' || form.fallbackMode === 'operator')
);
const needsAppRef = computed(
  () => form.mode === 'app' || form.fallbackMode === 'app'
);
const needsAiAppRef = computed(
  () => form.mode === 'ai' || form.fallbackMode === 'ai'
);

const operatorTargetError = computed(() => {
  if (!needsOperatorTarget.value || hasOperatorTarget.value) return '';

  return t('INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_TARGET_REQUIRED');
});

const appRefError = computed(() => {
  if (!needsAppRef.value || trimValue(form.appRef)) return '';

  return t('INBOX_MGMT.ADD.VOICE.FONOSTER.APP_REF.REQUIRED');
});

const aiAppRefError = computed(() => {
  if (!needsAiAppRef.value || trimValue(form.aiAppRef)) return '';

  return t('INBOX_MGMT.ADD.VOICE.FONOSTER.AI_APP_REF.REQUIRED');
});

const isInvalid = computed(() => {
  return (
    !numberRef.value ||
    Boolean(
      operatorTargetError.value || appRefError.value || aiAppRefError.value
    )
  );
});

const resetForm = () => {
  form.mode = routingPolicy.value.mode || 'operator';
  form.appRef = telephony.value.app_ref || '';
  form.aiAppRef = routingPolicy.value.ai_app_ref || '';
  form.operatorAgentRef = routingPolicy.value.operator_agent_ref || '';
  form.operatorAgentAor = routingPolicy.value.operator_agent_aor || '';
  form.operatorDistributionMode =
    routingPolicy.value.operator_distribution_mode || 'broadcast';
  form.fallbackMode = routingPolicy.value.fallback_mode || 'reject';
  form.fallbackMessage = routingPolicy.value.fallback_message || '';
  saveError.value = '';
};

const routePayload = () => ({
  mode: form.mode,
  app_ref: trimValue(form.appRef) || null,
  ai_app_ref: trimValue(form.aiAppRef) || null,
  operator_agent_ref: isTargetedOperatorDistribution.value
    ? trimValue(form.operatorAgentRef) || null
    : null,
  operator_agent_aor: isTargetedOperatorDistribution.value
    ? trimValue(form.operatorAgentAor) || null
    : null,
  operator_distribution_mode: form.operatorDistributionMode || 'broadcast',
  fallback_mode: form.fallbackMode || 'reject',
  fallback_message: trimValue(form.fallbackMessage) || null,
});

const saveRoute = async () => {
  if (isInvalid.value || isSaving.value) return;

  isSaving.value = true;
  saveError.value = '';

  try {
    await VoiceAPI.updateNumberRoute(numberRef.value, routePayload());
    await store.dispatch('inboxes/get');
    useAlert(t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.ROUTE_UPDATE_SUCCESS'));
    emit('saved');
  } catch (error) {
    saveError.value =
      error?.response?.data?.error ||
      error?.message ||
      t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.ROUTE_UPDATE_ERROR');
    useAlert(saveError.value);
  } finally {
    isSaving.value = false;
  }
};

watch(
  () => [
    props.inbox?.id,
    telephony.value?.app_ref,
    routingPolicy.value?.mode,
    routingPolicy.value?.ai_app_ref,
    routingPolicy.value?.operator_agent_ref,
    routingPolicy.value?.operator_agent_aor,
    routingPolicy.value?.operator_distribution_mode,
    routingPolicy.value?.fallback_mode,
    routingPolicy.value?.fallback_message,
  ],
  resetForm,
  { immediate: true }
);
</script>

<template>
  <form class="flex flex-col gap-4" @submit.prevent="saveRoute">
    <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
      <div class="flex flex-col gap-1">
        <label class="text-sm font-medium text-n-slate-12">
          {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.ROUTING_MODE') }}
        </label>
        <Select
          v-model="form.mode"
          class="w-full"
          :options="routeModeOptions"
          :disabled="isSaving"
        />
      </div>

      <div class="flex flex-col gap-1">
        <label class="text-sm font-medium text-n-slate-12">
          {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.FALLBACK_MODE') }}
        </label>
        <Select
          v-model="form.fallbackMode"
          class="w-full"
          :options="fallbackModeOptions"
          :disabled="isSaving"
        />
      </div>
    </div>

    <div class="flex flex-col gap-1">
      <label class="text-sm font-medium text-n-slate-12">
        {{ $t('INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_DISTRIBUTION.LABEL') }}
      </label>
      <Select
        v-model="form.operatorDistributionMode"
        class="w-full"
        :options="operatorDistributionModeOptions"
        :disabled="isSaving"
      />
    </div>

    <div
      v-if="needsOperatorTarget"
      class="grid grid-cols-1 gap-4 md:grid-cols-2"
    >
      <Input
        v-model="form.operatorAgentRef"
        :label="$t('INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_AGENT_REF.LABEL')"
        :placeholder="
          $t('INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_AGENT_REF.PLACEHOLDER')
        "
        :disabled="isSaving"
        :message="operatorTargetError"
        :message-type="operatorTargetError ? 'error' : 'info'"
      />
      <Input
        v-model="form.operatorAgentAor"
        :label="$t('INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_AGENT_AOR.LABEL')"
        :placeholder="
          $t('INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_AGENT_AOR.PLACEHOLDER')
        "
        :disabled="isSaving"
        :message="operatorTargetError"
        :message-type="operatorTargetError ? 'error' : 'info'"
      />
    </div>

    <Input
      v-if="needsAiAppRef"
      v-model="form.aiAppRef"
      :label="$t('INBOX_MGMT.ADD.VOICE.FONOSTER.AI_APP_REF.LABEL')"
      :placeholder="$t('INBOX_MGMT.ADD.VOICE.FONOSTER.AI_APP_REF.PLACEHOLDER')"
      :disabled="isSaving"
      :message="aiAppRefError"
      :message-type="aiAppRefError ? 'error' : 'info'"
    />

    <Input
      v-if="needsAppRef"
      v-model="form.appRef"
      :label="$t('INBOX_MGMT.ADD.VOICE.FONOSTER.APP_REF.LABEL')"
      :placeholder="$t('INBOX_MGMT.ADD.VOICE.FONOSTER.APP_REF.PLACEHOLDER')"
      :disabled="isSaving"
      :message="appRefError"
      :message-type="appRefError ? 'error' : 'info'"
    />

    <Input
      v-if="form.mode === 'reject' || form.fallbackMode === 'reject'"
      v-model="form.fallbackMessage"
      :label="$t('INBOX_MGMT.ADD.VOICE.FONOSTER.FALLBACK_MESSAGE.LABEL')"
      :placeholder="
        $t('INBOX_MGMT.ADD.VOICE.FONOSTER.FALLBACK_MESSAGE.PLACEHOLDER')
      "
      :disabled="isSaving"
    />

    <div
      v-if="saveError"
      class="rounded-lg border border-n-ruby-4 bg-n-ruby-2/40 p-3 text-sm text-n-ruby-11"
    >
      {{ saveError }}
    </div>

    <div class="flex justify-end">
      <Button
        type="submit"
        :label="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.UPDATE_ROUTE')"
        :disabled="isInvalid || isSaving"
        :is-loading="isSaving"
      />
    </div>
  </form>
</template>
