<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { usePhoneWidgetVisibility } from 'dashboard/composables/usePhoneWidgetVisibility';
import {
  phoneWidgetStatusColor,
  usePhoneWidgetStore,
} from 'dashboard/stores/phoneWidget';

// The sidebar renders this button only while the phone widget reports a
// browser SIP line for the employee (phoneWidgetStore.available).
const props = defineProps({
  isCollapsed: {
    type: Boolean,
    default: true,
  },
});

const { t } = useI18n();
const phoneWidgetStore = usePhoneWidgetStore();
const { isVisible, toggle } = usePhoneWidgetVisibility();

const label = computed(() =>
  isVisible.value
    ? t('PHONE_WIDGET.SIDEBAR_HIDE')
    : t('PHONE_WIDGET.SIDEBAR_SHOW')
);
const statusColor = computed(() =>
  phoneWidgetStatusColor(phoneWidgetStore.status)
);
</script>

<template>
  <li class="m-0 w-full list-none">
    <button
      type="button"
      data-testid="sidebar-phone-toggle"
      :data-status="phoneWidgetStore.status"
      :data-visible="isVisible"
      class="relative flex items-center rounded-lg"
      :class="[
        props.isCollapsed
          ? 'size-9 justify-center'
          : 'h-8 w-full gap-2 px-2 text-sm',
        // Shows/hides the phone (a disclosure, hence aria-expanded): filled
        // teal while the phone is on screen.
        isVisible
          ? 'bg-n-teal-9/10 text-n-teal-11 hover:bg-n-teal-9/20'
          : 'text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12',
      ]"
      :aria-label="label"
      :aria-expanded="isVisible"
      :title="label"
      @click="toggle"
    >
      <span class="i-lucide-phone size-4 shrink-0" />
      <span
        v-if="!props.isCollapsed"
        class="min-w-0 flex-1 truncate text-start"
      >
        {{ label }}
      </span>
      <span
        data-testid="sidebar-phone-toggle-status"
        aria-hidden="true"
        class="size-2 rounded-full"
        :class="[
          statusColor,
          props.isCollapsed
            ? 'absolute right-1 top-1 ring-2 ring-n-background'
            : 'shrink-0',
        ]"
      />
    </button>
  </li>
</template>
