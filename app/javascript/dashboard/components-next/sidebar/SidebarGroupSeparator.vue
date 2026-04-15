<script setup>
import { computed } from 'vue';
import { useRouter } from 'vue-router';
import Icon from 'next/icon/Icon.vue';

const props = defineProps({
  label: {
    type: String,
    default: '',
  },
  icon: {
    type: String,
    default: '',
  },
  to: {
    type: [Object, String],
    default: '',
  },
  active: {
    type: Boolean,
    default: false,
  },
  actionLabel: {
    type: String,
    default: '',
  },
  actionTo: {
    type: [Object, String],
    default: '',
  },
  actionTitle: {
    type: String,
    default: '',
  },
  actionIcon: {
    type: [Object, String],
    default: '',
  },
});

const router = useRouter();
const hasActionButton = computed(
  () => !props.actionLabel && props.actionTo && props.actionIcon
);

const handleActionClick = async () => {
  if (!props.actionTo) {
    return;
  }

  await router.push(props.actionTo);
};

const componentType = computed(() =>
  props.to && !hasActionButton.value ? 'router-link' : 'div'
);

const handleRootClick = async () => {
  if (componentType.value === 'div' && props.to) {
    await router.push(props.to);
  }
};
</script>

<template>
  <component
    :is="componentType"
    :to="componentType === 'router-link' ? to : undefined"
    :title="label"
    class="group flex items-center gap-2 px-2 py-1.5 rounded-lg h-8 select-none min-w-0"
    :class="{
      'text-n-slate-10 pointer-events-none': !to && !active,
      'text-n-slate-11 hover:bg-n-alpha-2 cursor-pointer': to && !active,
      'text-n-slate-11 cursor-pointer': active,
      'bg-n-alpha-2': active && !actionLabel,
    }"
    @click.stop="handleRootClick"
  >
    <Icon v-if="icon" :icon="icon" class="size-4" />
    <span
      class="text-sm leading-5 flex-grow min-w-0 truncate"
      :class="{
        'font-medium text-n-slate-12': active && !actionLabel,
      }"
    >
      {{ label }}
    </span>
    <span
      v-if="actionLabel"
      class="text-xs font-medium shrink-0 rounded-md px-2 py-0.5"
      :class="{
        'text-n-slate-10': !active,
        'text-n-slate-12 bg-n-alpha-2': active,
      }"
    >
      {{ actionLabel }}
    </span>
    <button
      v-else-if="hasActionButton"
      type="button"
      class="inline-flex flex-shrink-0 items-center justify-center rounded-md p-1 transition-all duration-150 text-n-slate-11 opacity-100 pointer-events-auto md:opacity-0 md:pointer-events-none md:group-hover:opacity-100 md:group-hover:pointer-events-auto hover:bg-n-alpha-2 hover:text-n-slate-12"
      :title="actionTitle"
      @click.prevent.stop="handleActionClick"
    >
      <Icon :icon="actionIcon" class="size-3.5" />
    </button>
  </component>
</template>
