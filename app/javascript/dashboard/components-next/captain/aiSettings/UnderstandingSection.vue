<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import {
  UNDERSTANDING_KEYS,
  WEB_UNDERSTANDING_KEYS,
} from 'dashboard/helper/captainAiSettings';

// «Понимание сообщений»: one toggle list for every agent of the workspace.
const props = defineProps({
  availability: { type: Object, default: () => ({}) },
  // Field errors of the page keyed by setting (see mapAiSettingsErrors).
  errors: { type: Object, default: () => ({}) },
  disabled: { type: Boolean, default: false },
});

const model = defineModel({ type: Object, required: true });

const { t } = useI18n();

const ROW_LABEL_KEYS = {
  voice_messages: 'VOICE',
  images: 'IMAGES',
  documents: 'DOCUMENTS',
  web_search: 'WEB_SEARCH',
  web_page_reading: 'WEB_PAGES',
};

const isWebConfigured = computed(
  () => props.availability?.web_access_configured !== false
);

const rows = computed(() =>
  UNDERSTANDING_KEYS.map(key => {
    const prefix = `CAPTAIN.AI_SETTINGS.UNDERSTANDING.${ROW_LABEL_KEYS[key]}`;
    return {
      key,
      title: t(prefix),
      description: t(`${prefix}_DESCRIPTION`),
      unavailable:
        WEB_UNDERSTANDING_KEYS.includes(key) && !isWebConfigured.value,
    };
  })
);

const update = (key, value) => {
  model.value = { ...model.value, [key]: value };
};
</script>

<template>
  <section
    id="understanding"
    data-testid="ai-settings-understanding"
    class="flex scroll-mt-4 flex-col gap-4"
  >
    <header class="flex flex-col gap-1">
      <h2 class="mb-0 text-heading-2 text-n-slate-12">
        {{ t('CAPTAIN.AI_SETTINGS.UNDERSTANDING.TITLE') }}
      </h2>
      <p class="mb-0 text-body-main text-n-slate-11">
        {{ t('CAPTAIN.AI_SETTINGS.UNDERSTANDING.DESCRIPTION') }}
      </p>
    </header>

    <div
      class="flex flex-col divide-y divide-n-weak rounded-xl outline outline-1 -outline-offset-1 outline-n-weak"
    >
      <div
        v-for="row in rows"
        :key="row.key"
        :data-testid="`understanding-${row.key}`"
        class="flex flex-col gap-1 px-4 py-3"
      >
        <div class="flex items-center justify-between gap-3">
          <span class="min-w-0 text-heading-3 text-n-slate-12">
            {{ row.title }}
          </span>
          <Switch
            :model-value="model[row.key] === true"
            :disabled="disabled || row.unavailable"
            :aria-label="row.title"
            @update:model-value="update(row.key, $event)"
          />
        </div>
        <p class="mb-0 text-body-main text-n-slate-11">
          {{ row.description }}
        </p>
        <p
          v-if="row.unavailable"
          data-testid="understanding-web-hint"
          class="mb-0 text-body-main text-n-amber-11"
        >
          {{ t('CAPTAIN.AI_SETTINGS.UNDERSTANDING.WEB_NOT_CONFIGURED') }}
        </p>
        <p
          v-if="errors[row.key]"
          role="alert"
          class="mb-0 text-body-main text-n-ruby-11"
        >
          {{ errors[row.key] }}
        </p>
      </div>
    </div>
  </section>
</template>
