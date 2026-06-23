<script setup>
import { computed } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import Icon from 'next/icon/Icon.vue';
import SidebarUnreadBadge from './SidebarUnreadBadge.vue';

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
  badge: {
    type: [Number, String],
    default: 0,
  },
  count: {
    type: [Number, String],
    default: null,
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
  actionItems: {
    type: Array,
    default: () => [],
  },
  compactLabel: {
    type: Boolean,
    default: false,
  },
});

const router = useRouter();
const route = useRoute();

const singleActionItem = computed(() => {
  if (!props.actionTo || !props.actionIcon) {
    return [];
  }

  return [
    {
      to: props.actionTo,
      title: props.actionTitle,
      icon: props.actionIcon,
    },
  ];
});

const actionItemsToRender = computed(() =>
  props.actionItems.length ? props.actionItems : singleActionItem.value
);

const hasActionButtons = computed(
  () => !props.actionLabel && actionItemsToRender.value.length > 0
);

const badgeCount = computed(() => Number(props.badge) || 0);
const hasPlainCount = computed(
  () => props.count !== null && typeof props.count !== 'undefined'
);
const plainCountLabel = computed(() => {
  const count = Number(props.count) || 0;
  return count > 999 ? '999+' : String(count);
});

const isActionActive = action => {
  if (action.active) return true;
  if (action.activeOn?.includes(route.name)) return true;
  if (!action.to) return false;

  return router.resolve(action.to).path === route.path;
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

const componentType = computed(() =>
  props.to && !hasActionButtons.value ? 'router-link' : 'div'
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
    class="sidebar-group-separator group flex items-center gap-2 px-2 py-1.5 rounded-lg h-8 select-none min-w-0"
    :class="{
      'text-n-slate-11 pointer-events-none': !to && !active,
      'text-n-slate-11 hover:bg-n-alpha-2 cursor-pointer': to && !active,
      'text-n-slate-11 cursor-pointer': active,
      'bg-n-alpha-2': active && !actionLabel,
    }"
    @click.stop="handleRootClick"
  >
    <Icon v-if="icon" :icon="icon" class="size-4" />
    <span
      class="sidebar-group-separator-label text-sm leading-5 flex-grow min-w-0 truncate"
      :class="{
        'font-medium text-n-slate-12': active && !actionLabel,
        '!text-xs': compactLabel,
      }"
    >
      {{ label }}
    </span>
    <span
      v-if="hasPlainCount"
      data-test-id="sidebar-plain-count"
      class="shrink-0 px-1 text-xs font-medium leading-5 tabular-nums text-current"
    >
      {{ plainCountLabel }}
    </span>
    <SidebarUnreadBadge v-else :value="badgeCount" />
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
    <div v-if="hasActionButtons" class="flex items-center gap-0.5">
      <button
        v-for="(action, index) in actionItemsToRender"
        :key="action.title || action.icon || index"
        type="button"
        class="inline-flex h-7 w-8 flex-shrink-0 items-center justify-center rounded-md transition-all duration-150 opacity-100 pointer-events-auto md:opacity-0 md:pointer-events-none md:group-hover:opacity-100 md:group-hover:pointer-events-auto hover:bg-n-alpha-2 hover:text-n-slate-12"
        :class="{
          'bg-n-alpha-2 text-n-slate-12': isActionActive(action),
          'text-n-slate-11': !isActionActive(action),
        }"
        :title="action.title"
        @click.prevent.stop="handleActionClick(action)"
      >
        <Icon :icon="action.icon" class="size-4" />
      </button>
    </div>
  </component>
</template>
