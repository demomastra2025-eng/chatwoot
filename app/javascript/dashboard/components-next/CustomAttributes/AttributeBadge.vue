<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Label from 'dashboard/components-next/label/Label.vue';

const props = defineProps({
  type: {
    type: String,
    default: 'resolution',
    validator: value => ['pre-chat', 'resolution', 'system'].includes(value),
  },
});

const { t } = useI18n();

const attributeConfig = {
  'pre-chat': {
    colorClass: 'text-n-blue-11',
    icon: 'i-lucide-message-circle',
    color: 'slate',
  },
  resolution: {
    colorClass: 'text-n-teal-11',
    icon: 'i-lucide-circle-check-big',
    color: 'slate',
  },
  system: {
    colorClass: 'text-n-slate-11',
    icon: 'i-lucide-shield-check',
    color: 'slate',
  },
};
const config = computed(
  () => attributeConfig[props.type] || attributeConfig.resolution
);

const label = computed(() => {
  if (props.type === 'pre-chat') return t('ATTRIBUTES_MGMT.BADGES.PRE_CHAT');
  if (props.type === 'system') return t('ATTRIBUTES_MGMT.BADGES.SYSTEM');

  return t('ATTRIBUTES_MGMT.BADGES.RESOLUTION');
});
</script>

<template>
  <Label :label="label" :color="config.color" compact>
    <template #icon>
      <Icon :icon="config.icon" class="size-3.5 text-n-slate-12" />
    </template>
  </Label>
</template>
