<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAccount } from 'dashboard/composables/useAccount';
import { useAlert } from 'dashboard/composables';

import Button from 'dashboard/components-next/button/Button.vue';
import Switch from 'next/switch/Switch.vue';
import TagInput from 'dashboard/components-next/taginput/TagInput.vue';

const STATUS_KEYS = ['open', 'resolved', 'pending', 'snoozed'];

const { t } = useI18n();
const { currentAccount, updateAccount } = useAccount();

const isSaving = ref(false);
const configDraft = ref({});

const normalizeReasons = values => [
  ...new Set(
    (Array.isArray(values) ? values : [values])
      .map(value => String(value || '').trim())
      .filter(Boolean)
  ),
];

const emptyConfig = () =>
  STATUS_KEYS.reduce((result, status) => {
    result[status] = { options: [], required: false };
    return result;
  }, {});

const normalizeConfig = rawConfig => {
  const source = rawConfig && typeof rawConfig === 'object' ? rawConfig : {};
  return STATUS_KEYS.reduce((result, status) => {
    const statusConfig = source[status] || {};
    result[status] = {
      options: normalizeReasons(statusConfig.options),
      required: Boolean(statusConfig.required),
    };
    return result;
  }, emptyConfig());
};

const statusTitle = status => {
  switch (status) {
    case 'resolved':
      return t('CONVERSATION_WORKFLOW.STATUS_REASONS.STATUS.RESOLVED');
    case 'pending':
      return t('CONVERSATION_WORKFLOW.STATUS_REASONS.STATUS.PENDING');
    case 'snoozed':
      return t('CONVERSATION_WORKFLOW.STATUS_REASONS.STATUS.SNOOZED');
    case 'open':
    default:
      return t('CONVERSATION_WORKFLOW.STATUS_REASONS.STATUS.OPEN');
  }
};

const statusDescription = status => {
  switch (status) {
    case 'resolved':
      return t('CONVERSATION_WORKFLOW.STATUS_REASONS.STATUS_HELP.RESOLVED');
    case 'pending':
      return t('CONVERSATION_WORKFLOW.STATUS_REASONS.STATUS_HELP.PENDING');
    case 'snoozed':
      return t('CONVERSATION_WORKFLOW.STATUS_REASONS.STATUS_HELP.SNOOZED');
    case 'open':
    default:
      return t('CONVERSATION_WORKFLOW.STATUS_REASONS.STATUS_HELP.OPEN');
  }
};

const statusRows = computed(() =>
  STATUS_KEYS.map(status => ({
    key: status,
    title: statusTitle(status),
    description: statusDescription(status),
  }))
);

const hasInvalidRequiredStatus = computed(() =>
  STATUS_KEYS.some(
    status =>
      configDraft.value[status]?.required &&
      normalizeReasons(configDraft.value[status]?.options).length === 0
  )
);

watch(
  currentAccount,
  () => {
    configDraft.value = normalizeConfig(
      currentAccount.value?.settings?.conversation_status_reason_config
    );
  },
  { deep: true, immediate: true }
);

const save = async () => {
  if (hasInvalidRequiredStatus.value) {
    useAlert(t('CONVERSATION_WORKFLOW.STATUS_REASONS.SAVE.REQUIRED_ERROR'));
    return;
  }

  try {
    isSaving.value = true;
    const normalizedConfig = normalizeConfig(configDraft.value);
    await updateAccount(
      { conversation_status_reason_config: normalizedConfig },
      { silent: true }
    );
    configDraft.value = normalizedConfig;
    useAlert(t('CONVERSATION_WORKFLOW.STATUS_REASONS.SAVE.SUCCESS'));
  } catch (error) {
    useAlert(t('CONVERSATION_WORKFLOW.STATUS_REASONS.SAVE.ERROR'));
  } finally {
    isSaving.value = false;
  }
};
</script>

<template>
  <div
    class="flex flex-col w-full outline-1 outline outline-n-container rounded-xl bg-n-solid-2 divide-y divide-n-weak"
  >
    <div class="flex flex-col gap-2 items-start px-5 py-4">
      <div class="flex justify-between items-center w-full gap-4">
        <div class="grid gap-2">
          <h3 class="text-heading-2 text-n-slate-12">
            {{ $t('CONVERSATION_WORKFLOW.STATUS_REASONS.TITLE') }}
          </h3>
          <p class="mb-0 text-body-para text-n-slate-11">
            {{ $t('CONVERSATION_WORKFLOW.STATUS_REASONS.DESCRIPTION') }}
          </p>
        </div>
        <Button
          size="sm"
          :label="$t('CONVERSATION_WORKFLOW.STATUS_REASONS.SAVE.BUTTON')"
          :is-loading="isSaving"
          :disabled="isSaving || hasInvalidRequiredStatus"
          @click="save"
        />
      </div>
    </div>

    <div class="divide-y divide-n-weak">
      <div
        v-for="status in statusRows"
        :key="status.key"
        class="grid gap-3 px-5 py-4 md:grid-cols-[minmax(0,16rem)_minmax(0,1fr)] md:items-start"
      >
        <div class="grid gap-1">
          <span class="text-sm font-medium text-n-slate-12">
            {{ status.title }}
          </span>
          <span class="text-xs leading-5 text-n-slate-11">
            {{ status.description }}
          </span>
        </div>

        <div class="grid gap-3">
          <TagInput
            v-model="configDraft[status.key].options"
            class="rounded-lg bg-n-alpha-black2 p-2 outline outline-1 outline-n-weak"
            allow-create
            :auto-open-dropdown="false"
            :placeholder="
              $t('CONVERSATION_WORKFLOW.STATUS_REASONS.OPTIONS_PLACEHOLDER')
            "
          />
          <div class="flex items-center gap-3">
            <Switch
              :model-value="configDraft[status.key].required"
              @update:model-value="configDraft[status.key].required = $event"
            />
            <div class="grid gap-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('CONVERSATION_WORKFLOW.STATUS_REASONS.REQUIRED') }}
              </span>
              <span class="text-xs leading-5 text-n-slate-11">
                {{ $t('CONVERSATION_WORKFLOW.STATUS_REASONS.REQUIRED_HELP') }}
              </span>
            </div>
          </div>
          <p
            v-if="
              configDraft[status.key].required &&
              normalizeReasons(configDraft[status.key].options).length === 0
            "
            class="mb-0 text-xs leading-5 text-n-ruby-10"
          >
            {{ $t('CONVERSATION_WORKFLOW.STATUS_REASONS.REQUIRED_ERROR') }}
          </p>
        </div>
      </div>
    </div>
  </div>
</template>
