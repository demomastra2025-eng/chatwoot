<script setup>
import { computed, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useI18n } from 'vue-i18n';

import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';

const props = defineProps({
  assignees: {
    type: Array,
    default: () => [],
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  modelValue: {
    type: [String, Number],
    default: '',
  },
});

const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();

const isOpen = ref(false);
const currentAssigneeId = computed(() => Number(props.modelValue));

const assigneeMetaById = computed(() =>
  props.assignees.reduce((result, assignee) => {
    result[Number(assignee.value)] = {
      label: assignee.label,
      thumbnail: assignee.thumbnail,
    };
    return result;
  }, {})
);

const currentAssignee = computed(
  () =>
    assigneeMetaById.value[currentAssigneeId.value] || {
      label: t('CRM.GENERAL.EMPTY_VALUE'),
      thumbnail: null,
    }
);

const menuItems = computed(() =>
  props.assignees.map(assignee => ({
    action: 'select',
    isSelected: Number(assignee.value) === currentAssigneeId.value,
    label: assignee.label,
    thumbnail: assignee.thumbnail,
    value: assignee.value,
  }))
);

const toggleMenu = () => {
  if (props.disabled || !menuItems.value.length) return;
  isOpen.value = !isOpen.value;
};

const handleAction = ({ value }) => {
  const nextAssigneeId = Number(value);

  if (nextAssigneeId !== currentAssigneeId.value) {
    emit('update:modelValue', nextAssigneeId);
  }

  isOpen.value = false;
};
</script>

<template>
  <div class="relative max-w-[8.5rem]" @click.stop>
    <OnClickOutside @trigger="isOpen = false">
      <button
        type="button"
        :disabled="disabled || !menuItems.length"
        class="inline-flex h-6 max-w-full items-center gap-1 rounded-md bg-n-alpha-black2 px-1.5 text-[10px] font-medium text-n-slate-12 transition-colors hover:bg-n-alpha-black3 disabled:cursor-not-allowed disabled:opacity-50"
        @click.stop="toggleMenu"
      >
        <span class="inline-flex min-w-0 items-center gap-1.5">
          <span class="truncate">{{ currentAssignee.label }}</span>
          <span
            class="inline-flex size-3 shrink-0 items-center justify-center opacity-55"
            aria-hidden="true"
          >
            <span
              class="size-3"
              :class="[
                isOpen ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down',
              ]"
            />
          </span>
        </span>
      </button>

      <DropdownMenu
        v-if="isOpen"
        :menu-items="menuItems"
        :show-search="assignees.length > 8"
        class="top-8 min-w-[12rem] ltr:right-0 rtl:left-0"
        @action="handleAction"
      />
    </OnClickOutside>
  </div>
</template>
