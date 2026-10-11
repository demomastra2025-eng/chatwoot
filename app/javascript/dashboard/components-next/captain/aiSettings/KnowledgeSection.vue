<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';

// «База знаний»: FAQ suggestions from resolved conversations.
defineProps({
  errors: { type: Object, default: () => ({}) },
  disabled: { type: Boolean, default: false },
});

const model = defineModel({ type: Object, required: true });

const { t } = useI18n();

const generateFromResolved = computed({
  get: () => model.value?.generate_from_resolved === true,
  set: value => {
    model.value = { ...model.value, generate_from_resolved: value };
  },
});
</script>

<template>
  <section
    id="knowledge"
    data-testid="ai-settings-knowledge"
    class="flex scroll-mt-4 flex-col gap-4"
  >
    <header class="flex flex-col gap-1">
      <h2 class="mb-0 text-heading-2 text-n-slate-12">
        {{ t('CAPTAIN.AI_SETTINGS.KNOWLEDGE.TITLE') }}
      </h2>
      <p class="mb-0 text-body-main text-n-slate-11">
        {{ t('CAPTAIN.AI_SETTINGS.KNOWLEDGE.DESCRIPTION') }}
      </p>
    </header>

    <div class="flex flex-col gap-1">
      <SettingsToggleSection
        v-model="generateFromResolved"
        data-testid="knowledge-faq-from-resolved"
        :header="t('CAPTAIN.AI_SETTINGS.KNOWLEDGE.FAQ_FROM_RESOLVED')"
        :description="
          t('CAPTAIN.AI_SETTINGS.KNOWLEDGE.FAQ_FROM_RESOLVED_DESCRIPTION')
        "
        :disabled="disabled"
      />
      <p
        v-if="errors.generate_from_resolved"
        role="alert"
        class="mb-0 text-body-main text-n-ruby-11"
      >
        {{ errors.generate_from_resolved }}
      </p>
    </div>
  </section>
</template>
