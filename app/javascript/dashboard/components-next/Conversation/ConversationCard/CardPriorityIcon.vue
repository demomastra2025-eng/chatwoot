<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { CONVERSATION_PRIORITY } from 'shared/constants/messages';

import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  priority: {
    type: String,
    default: '',
  },
  showEmpty: {
    type: Boolean,
    default: false,
  },
});
const { t } = useI18n();

const icons = {
  [CONVERSATION_PRIORITY.URGENT]: 'i-woot-priority-urgent',
  [CONVERSATION_PRIORITY.HIGH]: 'i-woot-priority-high',
  [CONVERSATION_PRIORITY.MEDIUM]: 'i-woot-priority-medium',
  [CONVERSATION_PRIORITY.LOW]: 'i-woot-priority-low',
};

const priorityLabels = computed(() => ({
  [CONVERSATION_PRIORITY.URGENT]: t('CONVERSATION.PRIORITY.OPTIONS.URGENT'),
  [CONVERSATION_PRIORITY.HIGH]: t('CONVERSATION.PRIORITY.OPTIONS.HIGH'),
  [CONVERSATION_PRIORITY.MEDIUM]: t('CONVERSATION.PRIORITY.OPTIONS.MEDIUM'),
  [CONVERSATION_PRIORITY.LOW]: t('CONVERSATION.PRIORITY.OPTIONS.LOW'),
}));

const iconName = computed(() => {
  if (props.priority && icons[props.priority]) {
    return icons[props.priority];
  }
  return props.showEmpty ? 'i-woot-priority-empty' : '';
});

const tooltipContent = computed(() => {
  if (props.priority && priorityLabels.value[props.priority]) {
    return priorityLabels.value[props.priority];
  }

  if (props.showEmpty) {
    return t('CONVERSATION.PRIORITY.OPTIONS.NONE');
  }

  return '';
});
</script>

<template>
  <Icon
    v-tooltip.top="{
      content: tooltipContent,
      delay: { show: 500, hide: 0 },
    }"
    :icon="iconName"
    class="size-4 text-n-slate-5"
  />
</template>
