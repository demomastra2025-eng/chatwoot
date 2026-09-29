<script setup>
import { computed } from 'vue';
import { useRouter } from 'vue-router';
import { useMapGetter } from 'dashboard/composables/store.js';
import Icon from 'next/icon/Icon.vue';

const props = defineProps({
  to: { type: [Object, String], default: '' },
  label: { type: String, default: '' },
  icon: { type: [String, Object], default: '' },
  expandable: { type: Boolean, default: false },
  isExpanded: { type: Boolean, default: false },
  isActive: { type: Boolean, default: false },
  hasActiveChild: { type: Boolean, default: false },
  actionTo: { type: [Object, String], default: '' },
  actionTitle: { type: String, default: '' },
  actionIcon: { type: [String, Object], default: '' },
  actionActive: { type: Boolean, default: false },
  actionHandler: { type: Function, default: null },
  actions: { type: Array, default: () => [] },
  getterKeys: { type: Object, default: () => ({}) },
});

const emit = defineEmits(['toggle']);
const router = useRouter();

const showBadge = useMapGetter(props.getterKeys.badge);
const dynamicCount = useMapGetter(props.getterKeys.count);
const count = computed(() =>
  dynamicCount.value > 999 ? '999+' : dynamicCount.value
);

const normalizedActions = computed(() => {
  if (props.actions.length) return props.actions;

  if ((props.actionTo || props.actionHandler) && props.actionIcon) {
    return [
      {
        to: props.actionTo,
        label: props.actionTitle,
        icon: props.actionIcon,
        active: props.actionActive,
        handler: props.actionHandler,
      },
    ];
  }

  return [];
});

const hasAction = computed(() => normalizedActions.value.length > 0);

const componentType = computed(() =>
  props.to && !hasAction.value ? 'router-link' : 'div'
);

const handleRootClick = async () => {
  if (componentType.value === 'div' && props.to) {
    await router.push(props.to);
  }

  emit('toggle');
};

const handleActionClick = async action => {
  if (action.handler) {
    action.handler();
    return;
  }

  if (!action.to) {
    return;
  }

  await router.push(action.to);
};
</script>

<template>
  <component
    :is="componentType"
    class="group flex w-full items-center gap-2 px-1.5 py-1 rounded-lg h-8 min-w-0"
    role="button"
    draggable="false"
    :to="componentType === 'router-link' ? props.to : undefined"
    :title="label"
    :class="{
      'bg-n-brand-solid text-n-brand-contrast hover:!bg-n-brand-solid font-medium':
        isActive || hasActiveChild,
      'text-n-slate-11 hover:bg-n-alpha-2': !isActive && !hasActiveChild,
    }"
    @click.stop="handleRootClick"
  >
    <div v-if="icon" class="relative flex items-center gap-2">
      <Icon v-if="icon" :icon="icon" class="size-4" />
      <span
        v-if="showBadge"
        class="size-2 -top-px ltr:-right-px rtl:-left-px bg-n-brand-solid absolute rounded-full border border-n-solid-2"
      />
    </div>
    <div class="flex items-center gap-1.5 flex-grow min-w-0 flex-1">
      <span
        class="truncate"
        :class="{
          'text-body-main': !isActive,
          'font-medium text-sm': isActive || hasActiveChild,
        }"
      >
        {{ label }}
      </span>
      <span
        v-if="dynamicCount && !expandable"
        class="rounded-md capitalize text-xs leading-5 font-medium text-center px-1 flex-shrink-0 outline outline-1"
        :class="{
          'bg-n-brand-solid text-n-brand-contrast outline-transparent':
            isActive,
          'bg-n-brand/10 text-n-brand outline-transparent': !isActive,
        }"
      >
        {{ count }}
      </span>
    </div>
    <button
      v-for="action in normalizedActions"
      :key="action.key || action.label"
      type="button"
      class="inline-flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-md transition-all duration-150"
      :class="{
        'bg-n-alpha-2 text-n-slate-12 opacity-100 pointer-events-auto':
          action.active,
        'text-n-slate-11 opacity-100 pointer-events-auto md:opacity-0 md:pointer-events-none md:group-hover:opacity-100 md:group-hover:pointer-events-auto hover:bg-n-alpha-2 hover:text-n-slate-12':
          !action.active,
      }"
      :title="action.label"
      :aria-label="action.label"
      @click.prevent.stop="handleActionClick(action)"
    >
      <Icon :icon="action.icon" class="size-5" />
    </button>
    <span
      v-if="expandable"
      v-show="isExpanded"
      class="i-lucide-chevron-up size-3"
      @click.stop="emit('toggle')"
    />
  </component>
</template>
