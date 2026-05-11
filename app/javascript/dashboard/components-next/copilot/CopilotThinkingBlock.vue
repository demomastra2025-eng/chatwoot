<script setup>
import Icon from '../../components-next/icon/Icon.vue';

defineProps({
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
  input: {
    type: String,
    default: '',
  },
  output: {
    type: String,
    default: '',
  },
});

const TOOL_TRACE_INPUT_LABEL = 'Input';
const TOOL_TRACE_OUTPUT_LABEL = 'Output';
</script>

<template>
  <div
    class="flex flex-col gap-2 p-3 rounded-lg bg-n-background/50 border border-n-weak hover:bg-n-background/80 transition-colors duration-200"
    :data-tool-name="toolName || undefined"
  >
    <div class="flex items-start gap-2">
      <Icon
        icon="i-lucide-sparkles"
        class="w-4 h-4 mt-0.5 flex-shrink-0 text-n-slate-9"
      />
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-2 text-sm text-n-slate-12">
          <span>{{ content }}</span>
          <span
            v-if="status"
            class="text-[11px] leading-4 px-1.5 py-0.5 rounded bg-n-alpha-3 text-n-slate-11 uppercase"
          >
            {{ status }}
          </span>
        </div>
        <div v-if="input || output" class="mt-2 space-y-1">
          <details
            v-if="input"
            class="rounded-md border border-n-weak bg-n-alpha-1"
            data-tool-trace-panel="input"
          >
            <summary
              class="cursor-pointer select-none px-2 py-1 text-xs font-medium text-n-slate-11"
            >
              {{ TOOL_TRACE_INPUT_LABEL }}
            </summary>
            <div
              class="max-h-64 overflow-auto whitespace-pre-wrap break-words px-2 pb-2 font-mono text-xs text-n-slate-12"
            >
              {{ input }}
            </div>
          </details>
          <details
            v-if="output"
            class="rounded-md border border-n-weak bg-n-alpha-1"
            data-tool-trace-panel="output"
          >
            <summary
              class="cursor-pointer select-none px-2 py-1 text-xs font-medium text-n-slate-11"
            >
              {{ TOOL_TRACE_OUTPUT_LABEL }}
            </summary>
            <div
              class="max-h-64 overflow-auto whitespace-pre-wrap break-words px-2 pb-2 font-mono text-xs text-n-slate-12"
            >
              {{ output }}
            </div>
          </details>
        </div>
      </div>
    </div>
  </div>
</template>
