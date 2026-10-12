<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';

// «Безопасность»: ONE switch that every agent of the workspace follows. It
// checks the customer's message before the agent works on it and the agent's
// reply before it is sent. The other safety checks (instruction hijacking,
// keys and passwords, platform rules) are platform settings and are not
// offered to the client; the page neither reads nor sends them.
const props = defineProps({
  errors: { type: Object, default: () => ({}) },
  disabled: { type: Boolean, default: false },
});

const model = defineModel({ type: Object, required: true });

const { t } = useI18n();

const moderationEnabled = computed({
  get: () => model.value?.moderation_enabled === true,
  set: value => {
    model.value = { ...model.value, moderation_enabled: value };
  },
});

const moderationError = computed(() => props.errors.moderation_enabled || '');
</script>

<template>
  <section
    id="safety"
    data-testid="ai-settings-safety"
    class="flex scroll-mt-4 flex-col gap-4"
  >
    <header class="flex flex-col gap-1">
      <h2 class="mb-0 text-heading-2 text-n-slate-12">
        {{ t('CAPTAIN.AI_SETTINGS.SAFETY.TITLE') }}
      </h2>
      <p class="mb-0 text-body-main text-n-slate-11">
        {{ t('CAPTAIN.AI_SETTINGS.SAFETY.DESCRIPTION') }}
      </p>
    </header>

    <div class="flex flex-col gap-1">
      <SettingsToggleSection
        v-model="moderationEnabled"
        data-testid="safety-moderation"
        :header="t('CAPTAIN.AI_SETTINGS.SAFETY.CHECK')"
        :description="t('CAPTAIN.AI_SETTINGS.SAFETY.CHECK_DESCRIPTION')"
        :disabled="disabled"
      />
      <p
        v-if="moderationError"
        role="alert"
        class="mb-0 text-body-main text-n-ruby-11"
      >
        {{ moderationError }}
      </p>
    </div>
  </section>
</template>
