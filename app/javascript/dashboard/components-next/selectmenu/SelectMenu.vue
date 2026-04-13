<script setup>
import { ref, computed } from 'vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  icon: {
    type: String,
    default: '',
  },
  options: {
    type: Array,
    required: true,
  },
  modelValue: {
    type: String,
    required: true,
  },
  label: {
    type: String,
    required: true,
  },
  subMenuPosition: {
    type: String,
    default: 'right',
    validator: value => {
      return ['right', 'left', 'bottom'].includes(value);
    },
  },
});

const emit = defineEmits(['update:modelValue']);

const isOpen = ref(false);

const labelValue = computed(() => props.label);

const toggleMenu = () => {
  isOpen.value = !isOpen.value;
};

const handleSelect = value => {
  emit('update:modelValue', value);
  isOpen.value = false;
};
</script>

<template>
  <div
    v-on-clickaway="() => (isOpen = false)"
    class="relative flex flex-col gap-1 w-fit"
  >
    <Button
      size="sm"
      color="slate"
      variant="faded"
      class="!w-fit max-w-40"
      :class="{ 'dark:!bg-n-alpha-2 !bg-n-slate-9/20': isOpen }"
      @click="toggleMenu"
    >
      <template #default>
        <span class="flex min-w-0 items-center gap-2">
          <Icon
            v-if="icon"
            :icon="icon"
            class="size-4 shrink-0 text-n-slate-11"
          />
          <span class="min-w-0 truncate">{{ labelValue }}</span>
          <Icon
            icon="i-lucide-chevron-down"
            class="size-4 shrink-0 text-n-slate-11"
          />
        </span>
      </template>
    </Button>
    <div
      v-if="isOpen"
      class="absolute select-none max-w-64 flex flex-col gap-1 bg-n-alpha-3 backdrop-blur-[100px] p-1 top-0 shadow-lg z-40 rounded-lg border border-n-weak dark:border-n-strong/50"
      :class="{
        'ltr:left-full rtl:right-full ltr:ml-1 rtl:mr-1':
          subMenuPosition === 'right',
        'ltr:right-full rtl:left-full ltr:mr-1 rtl:ml-1':
          subMenuPosition === 'left',
        'top-full mt-1 ltr:right-0 rtl:left-0': subMenuPosition === 'bottom',
      }"
    >
      <Button
        v-for="option in options"
        :key="option.value"
        :label="option.label"
        :icon="option.value === modelValue ? 'i-lucide-check' : ''"
        size="sm"
        variant="ghost"
        color="slate"
        trailing-icon
        class="!justify-end !px-2.5 !h-7"
        :class="{ '!bg-n-alpha-2': option.value === modelValue }"
        @click="handleSelect(option.value)"
      />
    </div>
  </div>
</template>
