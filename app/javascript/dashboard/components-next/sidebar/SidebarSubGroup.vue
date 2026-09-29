<script setup>
import { computed } from 'vue';
import { useRouter } from 'vue-router';
import SidebarGroupLeaf from './SidebarGroupLeaf.vue';
import SidebarGroupSeparator from './SidebarGroupSeparator.vue';
import Icon from 'next/icon/Icon.vue';
import { getSidebarChildDisplayLabel } from './sidebarDisplayLabels';

import { useSidebarContext } from './provider';

const props = defineProps({
  isExpanded: { type: Boolean, default: false },
  label: { type: String, required: true },
  icon: { type: [Object, String], required: true },
  children: { type: Array, default: undefined },
  activeChildNames: { type: Array, default: () => [] },
  to: { type: [Object, String], default: '' },
  headerActive: { type: Boolean, default: false },
  badge: { type: [Number, String], default: 0 },
  count: { type: [Number, String], default: null },
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
    :count="count"
    :action-label="actionLabel"
    :action-to="actionTo"
    :action-title="actionTitle"
    :action-icon="actionIcon"
    :action-items="actionItems"
    :compact-label="compactHeader"
    class="my-1"
  />
  <ul v-if="children.length" class="m-0 list-none reset-base min-w-0">
    <!-- Each element has h-8, which is 32px. We show roughly a third more than the previous 14rem + 16px limit. -->
    <div
      class="min-w-0"
      :class="{
        'max-h-[20rem] overflow-y-scroll no-scrollbar': isScrollable,
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
  </ul>
</template>
