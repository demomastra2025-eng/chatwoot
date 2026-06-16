<script setup>
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';
import SidebarGroupLeaf from './SidebarGroupLeaf.vue';
import SidebarGroupSeparator from './SidebarGroupSeparator.vue';
import Icon from 'next/icon/Icon.vue';
import { getSidebarChildDisplayLabel } from './sidebarDisplayLabels';

import { useSidebarContext } from './provider';
import { useEventListener } from '@vueuse/core';

const props = defineProps({
  isExpanded: { type: Boolean, default: false },
  label: { type: String, required: true },
  icon: { type: [Object, String], required: true },
  children: { type: Array, default: undefined },
  activeChildNames: { type: Array, default: () => [] },
  to: { type: [Object, String], default: '' },
  headerActive: { type: Boolean, default: false },
  badge: { type: [Number, String], default: 0 },
  actionLabel: { type: String, default: '' },
  actionTo: { type: [Object, String], default: '' },
  actionTitle: { type: String, default: '' },
  actionIcon: { type: [Object, String], default: '' },
  actionItems: { type: Array, default: () => [] },
  footerActionItems: { type: Array, default: () => [] },
  compactHeader: { type: Boolean, default: false },
});

const { isAllowed } = useSidebarContext();
const router = useRouter();
const scrollableContainer = ref(null);

const accessibleItems = computed(() =>
  props.children.filter(child => {
    return child.to && isAllowed(child.to);
  })
);

const hasAccessibleItems = computed(() => {
  return accessibleItems.value.length > 0;
});

const isScrollable = computed(() => {
  return accessibleItems.value.length > 7;
});

const scrollEnd = ref(false);

const getChildDisplayLabel = child =>
  getSidebarChildDisplayLabel(child, props.isExpanded);

const handleFooterActionClick = async action => {
  if (action.handler) {
    action.handler();
    return;
  }

  if (action.to) {
    await router.push(action.to);
  }
};

// set scrollEnd to true when the scroll reaches the end
useEventListener(scrollableContainer, 'scroll', () => {
  const { scrollHeight, scrollTop, clientHeight } = scrollableContainer.value;
  scrollEnd.value = scrollHeight - scrollTop === clientHeight;
});
</script>

<template>
  <SidebarGroupSeparator
    v-if="hasAccessibleItems"
    v-show="isExpanded"
    :label
    :icon
    :to="to"
    :active="headerActive"
    :badge="badge"
    :action-label="actionLabel"
    :action-to="actionTo"
    :action-title="actionTitle"
    :action-icon="actionIcon"
    :action-items="actionItems"
    :compact-label="compactHeader"
    class="my-1"
  />
  <ul
    v-if="children.length"
    class="m-0 list-none reset-base relative group min-w-0"
  >
    <!-- Each element has h-8, which is 32px, we will show 7 items with one hidden at the end,
    which is 14rem. Then we add 16px so that we have some text visible from the next item  -->
    <div
      ref="scrollableContainer"
      class="min-w-0"
      :class="{
        'max-h-[calc(14rem+16px)] overflow-y-scroll no-scrollbar': isScrollable,
      }"
    >
      <SidebarGroupLeaf
        v-for="child in children"
        v-show="isExpanded || activeChildNames.includes(child.name)"
        v-bind="child"
        :key="child.name"
        :label="getChildDisplayLabel(child)"
        :active="activeChildNames.includes(child.name)"
      />
      <button
        v-for="(action, index) in footerActionItems"
        v-show="isExpanded"
        :key="action.title || action.icon || index"
        type="button"
        class="mt-1 flex h-7 w-full items-center gap-1.5 rounded-lg border border-dashed border-n-weak px-1.5 text-xs text-n-slate-10 hover:border-n-slate-7 hover:bg-n-alpha-1 hover:text-n-slate-12"
        :title="action.title"
        @click.prevent.stop="handleFooterActionClick(action)"
      >
        <Icon v-if="action.icon" :icon="action.icon" class="size-3.5" />
        <span class="min-w-0 truncate">{{ action.title }}</span>
      </button>
    </div>
    <div
      v-if="isScrollable && isExpanded"
      v-show="!scrollEnd"
      class="absolute bg-gradient-to-t from-n-background w-full h-12 to-transparent -bottom-1 pointer-events-none flex items-end justify-end px-2 animate-fade-in-up"
    >
      <svg
        width="16"
        height="24"
        viewBox="0 0 16 24"
        fill="none"
        class="text-n-slate-9 opacity-50 group-hover:opacity-100"
        xmlns="http://www.w3.org/2000/svg"
      >
        <path
          d="M4 4L8 8L12 4"
          stroke="currentColor"
          opacity="0.5"
          stroke-width="1.33333"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <path
          d="M4 10L8 14L12 10"
          stroke="currentColor"
          opacity="0.75"
          stroke-width="1.33333"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <path
          d="M4 16L8 20L12 16"
          stroke="currentColor"
          stroke-width="1.33333"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
    </div>
  </ul>
</template>
