<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
import Icon from '../../components-next/icon/Icon.vue';

const props = defineProps({
  content: {
    type: String,
    required: true,
  },
  toolName: {
    type: String,
    default: '',
  },
  status: {
    type: String,
    default: '',
  },
  reasoning: {
    type: String,
    default: '',
  },
  input: {
    type: String,
    default: '',
  },
  output: {
    type: String,
    default: '',
  },
});

const { t } = useI18n();

const isScenarioHandoff = computed(() =>
  props.toolName.startsWith('handoff_to_scenario_')
);

const isReasoningBlock = computed(() => props.reasoning && !props.toolName);

const toolIcon = computed(() => {
  if (isReasoningBlock.value) return 'i-lucide-brain';
  if (isScenarioHandoff.value) return 'i-lucide-route';
  if (props.toolName) return 'i-lucide-wrench';
  return 'i-lucide-sparkles';
});

const humanizedScenarioName = computed(() => {
  if (!isScenarioHandoff.value) return '';

  return props.toolName
    .replace(/^handoff_to_scenario_/, '')
    .replace(/_agent$/, '')
    .replace(/^\d+_/, '')
    .replace(/_/g, ' ')
    .replace(/\b\w/g, char => char.toUpperCase());
});

const displayTitle = computed(() => {
  if (isScenarioHandoff.value) {
    return t('CAPTAIN.COPILOT.TOOL_TRACE.SCENARIO_HANDOFF', {
      scenario: humanizedScenarioName.value || props.toolName,
    });
  }

  return props.toolName || props.content;
});

const statusLabel = computed(() => {
  if (!props.status) return '';

  const labels = {
    start: t('CAPTAIN.COPILOT.TOOL_STATUS.RUNNING'),
    progress: t('CAPTAIN.COPILOT.TOOL_STATUS.RUNNING'),
    finish: t('CAPTAIN.COPILOT.TOOL_STATUS.COMPLETED'),
    failed: t('CAPTAIN.COPILOT.TOOL_STATUS.FAILED'),
    suppressed: t('CAPTAIN.COPILOT.TOOL_STATUS.SKIPPED'),
  };

  return labels[props.status] || props.status;
});

const statusClass = computed(() => {
  const classes = {
    start: 'border-n-amber-7 text-n-amber-11',
    progress: 'border-n-amber-7 text-n-amber-11',
    finish: 'border-n-teal-7 text-n-teal-11',
    failed: 'border-n-ruby-7 text-n-ruby-11',
    suppressed: 'border-n-slate-7 text-n-slate-11',
  };

  return classes[props.status] || 'border-n-weak text-n-slate-11';
});

const tracePanels = computed(() =>
  [
    {
      id: 'input',
      label: t('CAPTAIN.COPILOT.TOOL_TRACE.INPUT'),
      copyLabel: t('CAPTAIN.COPILOT.TOOL_TRACE.COPY_INPUT'),
      icon: 'i-lucide-log-in',
      value: props.input,
    },
    {
      id: 'output',
      label: t('CAPTAIN.COPILOT.TOOL_TRACE.OUTPUT'),
      copyLabel: t('CAPTAIN.COPILOT.TOOL_TRACE.COPY_OUTPUT'),
      icon: 'i-lucide-log-out',
      value: props.output,
    },
  ].filter(panel => panel.value)
);

const copyTracePanel = async value => {
  try {
    await copyTextToClipboard(value);
    useAlert(t('CAPTAIN.COPILOT.TOOL_TRACE.COPY_SUCCESS'));
  } catch {
    useAlert(t('CAPTAIN.COPILOT.TOOL_TRACE.COPY_ERROR'));
  }
};
</script>

<template>
  <div
    class="flex flex-col gap-1.5 rounded-lg border border-n-weak bg-n-solid-2 p-2"
    :data-tool-name="toolName || undefined"
  >
    <div class="flex items-start gap-1.5">
      <Icon
        :icon="toolIcon"
        class="mt-0.5 h-3.5 w-3.5 flex-shrink-0 text-n-slate-9"
      />
      <div class="min-w-0 flex-1">
        <div
          class="flex flex-wrap items-center gap-1.5 text-xs text-n-slate-12"
        >
          <span class="font-medium break-words">{{ displayTitle }}</span>
          <span
            v-if="statusLabel"
            class="rounded-full border px-1.5 py-0.5 text-[10px] font-medium leading-3"
            :class="statusClass"
          >
            {{ statusLabel }}
          </span>
        </div>
        <p
          v-if="reasoning"
          class="mt-1 whitespace-pre-wrap break-words text-xs leading-5 text-n-slate-11"
        >
          {{ reasoning }}
        </p>
        <div v-if="tracePanels.length" class="mt-2 space-y-1.5">
          <details
            v-for="panel in tracePanels"
            :key="panel.id"
            class="tool-trace-panel group overflow-hidden rounded-md border border-n-weak bg-n-solid-1"
            :data-tool-trace-panel="panel.id"
          >
            <summary
              class="flex cursor-pointer select-none list-none items-center justify-between gap-2 px-2 py-1 text-xs font-medium text-n-slate-11"
            >
              <span class="flex min-w-0 items-center gap-1.5">
                <Icon :icon="panel.icon" class="h-3.5 w-3.5 flex-shrink-0" />
                <span class="truncate">{{ panel.label }}</span>
              </span>
              <Icon
                icon="i-lucide-chevron-down"
                class="h-3.5 w-3.5 text-n-slate-9 transition-transform group-open:rotate-180"
              />
            </summary>
            <div class="relative border-t border-n-weak">
              <button
                v-tooltip.top="panel.copyLabel"
                type="button"
                class="skip-context-menu absolute right-1 top-1 inline-flex h-8 w-8 items-center justify-center text-n-slate-11 hover:text-n-slate-12"
                :aria-label="panel.copyLabel"
                @click.stop.prevent="copyTracePanel(panel.value)"
              >
                <Icon icon="i-lucide-copy" class="h-6 w-6" />
              </button>
              <div
                class="max-h-64 overflow-auto whitespace-pre-wrap break-words px-2 pb-2 pt-9 font-mono text-xs text-n-slate-12"
              >
                {{ panel.value }}
              </div>
            </div>
          </details>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.tool-trace-panel > summary::-webkit-details-marker {
  display: none;
}

.tool-trace-panel > summary::marker {
  content: '';
}
</style>
