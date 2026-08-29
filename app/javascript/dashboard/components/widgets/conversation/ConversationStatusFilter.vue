<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

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
const isOpen = ref(false);

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

const closeDropdown = () => {
  isOpen.value = false;
};

const selectStatus = value => {
  closeDropdown();
  if (value !== props.modelValue) emit('update:modelValue', value);
};
</script>

<template>
  <div
    v-on-clickaway="closeDropdown"
    class="relative min-w-0 shrink"
    data-test-id="conversation-status-filter"
  >
    <button
      type="button"
      class="flex h-8 max-w-full min-w-0 items-center gap-1 rounded-lg px-1.5 py-0 text-[15px] font-medium leading-5 text-n-slate-12 transition-colors duration-150 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-n-brand"
      :aria-expanded="isOpen"
      aria-haspopup="menu"
      data-test-id="conversation-status-filter-trigger"
      @click="isOpen = !isOpen"
      @keydown.escape.stop.prevent="closeDropdown"
    >
      <span class="min-w-0 max-w-36 truncate text-left rtl:text-right">
        {{ activeLabel }}
      </span>
      <i
        class="i-lucide-chevron-down size-3.5 shrink-0 text-n-slate-10 transition-transform duration-150"
        :class="{ 'rotate-180': isOpen }"
      />
    </button>

    <div
      v-if="isOpen"
      class="absolute z-40 mt-1 w-48 rounded-xl bg-n-alpha-3 p-1.5 shadow-lg outline outline-1 -outline-offset-1 outline-n-weak backdrop-blur-[100px] ltr:left-0 rtl:right-0"
      role="menu"
      data-test-id="conversation-status-filter-menu"
    >
      <button
        v-for="option in options"
        :key="option.value"
        type="button"
        class="flex h-8 w-full items-center gap-2 rounded-lg px-2 text-left text-sm text-n-slate-11 transition-colors duration-150 hover:text-n-slate-12 rtl:text-right"
        :class="{
          'text-n-slate-12': option.value === modelValue,
        }"
        role="menuitemradio"
        :aria-checked="option.value === modelValue"
        @click="selectStatus(option.value)"
      >
        <span class="min-w-0 flex-1 truncate">{{ option.label }}</span>
        <i
          v-if="option.value === modelValue"
          class="i-lucide-check size-4 shrink-0"
        />
      </button>
    </div>
  </div>
</template>
