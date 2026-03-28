<script setup>
import { computed, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useI18n } from 'vue-i18n';

import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';

const props = defineProps({
  disabled: {
    type: Boolean,
    default: false,
  },
  modelValue: {
    type: [String, Number],
    default: '',
  },
  owners: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();

const isOpen = ref(false);
const currentOwnerId = computed(() => Number(props.modelValue));

const ownerMetaById = computed(() =>
  props.owners.reduce((result, owner) => {
    result[Number(owner.value)] = {
      label: owner.label,
      thumbnail: owner.thumbnail,
    };
    return result;
  }, {})
);

const currentOwner = computed(
  () =>
    ownerMetaById.value[currentOwnerId.value] || {
      label: t('CRM.GENERAL.EMPTY_VALUE'),
      thumbnail: null,
    }
);

const menuItems = computed(() =>
  props.owners.map(owner => ({
    action: 'select',
    isSelected: Number(owner.value) === currentOwnerId.value,
    label: owner.label,
    thumbnail: owner.thumbnail,
    value: owner.value,
  }))
);

const toggleMenu = () => {
  if (props.disabled || !menuItems.value.length) return;
  isOpen.value = !isOpen.value;
};

const handleAction = ({ value }) => {
  const nextOwnerId = Number(value);

  if (nextOwnerId !== currentOwnerId.value) {
    emit('update:modelValue', nextOwnerId);
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
          <span class="truncate">{{ currentOwner.label }}</span>
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
        :show-search="owners.length > 8"
        class="top-8 min-w-[12rem] ltr:right-0 rtl:left-0"
        @action="handleAction"
      />
    </OnClickOutside>
  </div>
</template>
