<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAccount } from 'dashboard/composables/useAccount';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import Button from 'dashboard/components-next/button/Button.vue';

// «Дожимы» block of the agent page side column: on/off and the number of
// steps; the button opens the «Дожимы» tab. Hidden without CAPTAIN_V2, like
// the tab itself.
const props = defineProps({
  assistant: { type: Object, required: true },
});

const emit = defineEmits(['open']);

const { t } = useI18n();
const { isCloudFeatureEnabled } = useAccount();

const isAvailable = computed(() =>
  isCloudFeatureEnabled(FEATURE_FLAGS.CAPTAIN_V2)
);
const settings = computed(
  () => props.assistant?.config?.follow_up_settings || {}
);
const isEnabled = computed(() => settings.value.enabled === true);
const stepsCount = computed(() =>
  Array.isArray(settings.value.steps) ? settings.value.steps.length : 0
);
</script>

<template>
  <section
    v-if="isAvailable"
    class="flex flex-col outline outline-1 -outline-offset-1 outline-n-container rounded-xl bg-n-solid-2 divide-y divide-n-weak"
    data-test="agent-follow-ups-summary"
  >
    <div class="flex items-center justify-between gap-3 px-5 py-4">
      <h3 class="mb-0 text-heading-2 text-n-slate-12">
        {{ t('CAPTAIN.AGENT_PAGE.FOLLOW_UPS.TITLE') }}
      </h3>
      <span
        class="shrink-0 text-body-main"
        :class="isEnabled ? 'text-n-teal-11' : 'text-n-slate-11'"
        data-test="agent-follow-ups-state"
      >
        {{
          isEnabled
            ? t('CAPTAIN.AGENT_PAGE.FOLLOW_UPS.ON')
            : t('CAPTAIN.AGENT_PAGE.FOLLOW_UPS.OFF')
        }}
      </span>
    </div>
    <div class="flex items-center justify-between gap-3 px-5 py-4">
      <p
        class="mb-0 text-body-main text-n-slate-11"
        data-test="agent-follow-ups-steps"
      >
        {{ t('CAPTAIN.AGENT_PAGE.FOLLOW_UPS.STEPS', { count: stepsCount }) }}
      </p>
      <Button
        :label="t('CAPTAIN.AGENT_PAGE.FOLLOW_UPS.OPEN')"
        variant="link"
        size="sm"
        class="shrink-0"
        @click="emit('open')"
      />
    </div>
  </section>
</template>
