<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import SelectMenu from 'dashboard/components-next/selectmenu/SelectMenu.vue';

const props = defineProps({
  modelValue: {
    type: String,
    required: true,
  },
  showAi: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();

const statusValues = computed(() => [
  'all',
  'open',
  ...(props.showAi ? ['pending'] : []),
  'snoozed',
  'resolved',
]);

const statusLabels = computed(() => ({
  all: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.all.TEXT'),
  open: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.open.TEXT'),
  pending: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.pending.TEXT'),
  snoozed: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.snoozed.TEXT'),
  resolved: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.resolved.TEXT'),
}));

const options = computed(() =>
  statusValues.value.map(value => ({
    value,
    label: statusLabels.value[value],
  }))
);

const activeLabel = computed(
  () =>
    options.value.find(option => option.value === props.modelValue)?.label ||
    options.value[0]?.label ||
    ''
);
</script>

<template>
  <SelectMenu
    icon="i-lucide-list-filter"
    :model-value="modelValue"
    :options="options"
    :label="activeLabel"
    sub-menu-position="bottom"
    @update:model-value="emit('update:modelValue', $event)"
  />
</template>
