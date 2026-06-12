<script setup>
import { ref, watch, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Icon from '../icon/Icon.vue';
import CopilotThinkingBlock from './CopilotThinkingBlock.vue';

const props = defineProps({
  messages: { type: Array, required: true },
  defaultCollapsed: { type: Boolean, default: false },
});
const { t, locale } = useI18n();
const isExpanded = ref(!props.defaultCollapsed);

const toolCount = computed(
  () =>
    props.messages.filter(copilotMessage => copilotMessage?.message?.toolName)
      .length
);

const pluralCategoryKeyMap = {
  one: 'ONE',
  few: 'FEW',
  many: 'MANY',
  other: 'MANY',
  zero: 'MANY',
  two: 'FEW',
};

const currentLocale = computed(() => locale?.value || locale || 'en');

const toolCountPluralKey = computed(() => {
  const category = new Intl.PluralRules(currentLocale.value).select(
    toolCount.value
  );

  return pluralCategoryKeyMap[category] || 'MANY';
});

const toolCountLabel = computed(() => {
  if (!toolCount.value) return '';

  const params = {
    count: toolCount.value,
  };

  if (toolCountPluralKey.value === 'ONE') {
    return t('CAPTAIN.COPILOT.TOOL_COUNT.ONE', params);
  }

  if (toolCountPluralKey.value === 'FEW') {
    return t('CAPTAIN.COPILOT.TOOL_COUNT.FEW', params);
  }

  return t('CAPTAIN.COPILOT.TOOL_COUNT.MANY', params);
});

const showStepsLabel = computed(() =>
  [t('CAPTAIN.COPILOT.SHOW_STEPS'), toolCountLabel.value]
    .filter(Boolean)
    .join(' - ')
);

watch(
  () => props.defaultCollapsed,
  newValue => {
    if (newValue) {
      isExpanded.value = false;
    }
  }
);
</script>

<template>
  <div class="flex flex-col gap-2">
    <div class="flex items-center justify-between gap-2">
      <button
        class="group -ml-3 flex min-w-0 items-center gap-2 text-xs text-n-slate-10 transition-colors duration-200 hover:text-n-slate-11"
        @click="isExpanded = !isExpanded"
      >
        <Icon
          :icon="
            isExpanded ? 'i-lucide-chevron-down' : 'i-lucide-chevron-right'
          "
          class="h-4 w-4 flex-shrink-0 transition-transform duration-200 group-hover:scale-110"
        />
        <span class="truncate text-xs font-medium text-n-slate-10">
          {{ showStepsLabel }}
        </span>
      </button>
      <slot name="headerAction" />
    </div>
    <div
      v-show="isExpanded"
      class="space-y-3 transition-all duration-200"
      :class="{
        'opacity-100': isExpanded,
        'opacity-0 max-h-0 overflow-hidden': !isExpanded,
      }"
    >
      <CopilotThinkingBlock
        v-for="copilotMessage in messages"
        :key="copilotMessage.id"
        :content="copilotMessage.message.content"
        :reasoning="copilotMessage.message.reasoning"
        :tool-name="copilotMessage.message.toolName"
        :status="copilotMessage.message.status"
        :input="copilotMessage.message.input"
        :output="copilotMessage.message.output"
      />
    </div>
  </div>
</template>
