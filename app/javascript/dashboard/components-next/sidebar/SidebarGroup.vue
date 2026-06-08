<script setup>
import { computed, onMounted, onUnmounted, watch, nextTick, ref } from 'vue';
import { useSidebarContext, usePopoverState } from './provider';
import { useRoute, useRouter } from 'vue-router';
import Policy from 'dashboard/components/policy.vue';
import Icon from 'next/icon/Icon.vue';
import SidebarGroupHeader from './SidebarGroupHeader.vue';
import SidebarGroupLeaf from './SidebarGroupLeaf.vue';
import SidebarSubGroup from './SidebarSubGroup.vue';
import SidebarGroupEmptyLeaf from './SidebarGroupEmptyLeaf.vue';
import SidebarCollapsedPopover from './SidebarCollapsedPopover.vue';
import { getSidebarChildDisplayLabel } from './sidebarDisplayLabels';

const props = defineProps({
  name: { type: String, required: true },
  label: { type: String, required: true },
  icon: { type: [String, Object, Function], default: null },
  to: { type: Object, default: null },
  activeOn: { type: Array, default: () => [] },
  actionTo: { type: [Object, String], default: '' },
  actionTitle: { type: String, default: '' },
  actionIcon: { type: [String, Object], default: '' },
  actionActiveOn: { type: Array, default: () => [] },
  children: { type: Array, default: undefined },
  getterKeys: { type: Object, default: () => ({}) },
});

const {
  expandedItem,
  setExpandedItem,
  resolvePath,
  resolvePermissions,
  resolveFeatureFlag,
  isAllowed,
  isCollapsed,
  isResizing,
} = useSidebarContext();

const {
  activePopover,
  setActivePopover,
  closeActivePopover,
  scheduleClose,
  cancelClose,
} = usePopoverState();

const navigableChildren = computed(() => {
  return (
    props.children?.flatMap(child => {
      if (!child.children) return child;
      return child.to ? [child, ...child.children] : child.children;
    }) || []
  );
});

const route = useRoute();
const router = useRouter();
const isExpanded = computed(() => expandedItem.value === props.name);
const isExpandable = computed(() => props.children);
const hasChildren = computed(
  () => Array.isArray(props.children) && props.children.length > 0
);

// Use shared popover state - only one popover can be open at a time
const isPopoverOpen = computed(() => activePopover.value === props.name);
const triggerRef = ref(null);
const triggerRect = ref({ top: 0, left: 0, bottom: 0, right: 0 });

const openPopover = () => {
  if (triggerRef.value) {
    const rect = triggerRef.value.getBoundingClientRect();
    triggerRect.value = {
      top: rect.top,
      left: rect.left,
      bottom: rect.bottom,
      right: rect.right,
    };
  }
  setActivePopover(props.name);
};

const closePopover = () => {
  if (activePopover.value === props.name) {
    closeActivePopover();
  }
};

const handleMouseEnter = () => {
  if (!hasChildren.value || isResizing.value) return;
  cancelClose();
  openPopover();
};

const handleMouseLeave = () => {
  if (!hasChildren.value) return;
  scheduleClose(200);
};

const handlePopoverMouseEnter = () => {
  cancelClose();
};

const handlePopoverMouseLeave = () => {
  scheduleClose(100);
};

// Close popover when mouse leaves the window
const handleWindowBlur = () => {
  closeActivePopover();
};

const accessibleItems = computed(() => {
  if (!hasChildren.value) return [];
  return props.children.filter(child => {
    // If a item has no link, it means it's just a subgroup header
    // So we don't need to check for permissions here, because there's nothing to
    // access here anyway
    return child.to && isAllowed(child.to);
  });
});

const hasAccessibleChildren = computed(() => {
  return accessibleItems.value.length > 0;
});

const headerActionItem = computed(() => {
  if (props.actionTo && props.actionIcon) {
    return {
      to: props.actionTo,
      label: props.actionTitle,
      icon: props.actionIcon,
      activeOn: props.actionActiveOn,
    };
  }

  if (!hasChildren.value) {
    return null;
  }

  return (
    props.children.find(
      child => child.headerAction && child.to && isAllowed(child.to)
    ) || null
  );
});

const isActive = computed(() => {
  if (props.to) {
    if (route.path === resolvePath(props.to)) return true;

    return props.activeOn.includes(route.name);
  }

  return false;
});

const queryMatches = child => {
  const childQuery = child?.to?.query || {};

  return Object.entries(childQuery).every(([key, value]) => {
    const routeValue =
      key === 'status'
        ? (route.query[key] ?? 'open')
        : (route.query[key] ?? '');

    return String(routeValue) === String(value);
  });
};

const paramsMatch = child => {
  const childParams = child?.to?.params || {};
  const routeParams = route.params || {};
  const inboxIdAliases = {
    inbox_id: 'inboxId',
    inboxId: 'inbox_id',
  };

  return Object.keys(childParams).every(key => {
    const childParam = String(childParams[key]);
    const routeParam = String(routeParams[key] || '');
    const routeParamAlias = routeParams[inboxIdAliases[key]] || '';

    if (key === 'navigationPath') {
      return (
        childParam === String(route.name || '') || childParam === routeParam
      );
    }

    return (
      childParam === routeParam ||
      (routeParamAlias && childParam === String(routeParamAlias))
    );
  });
};

const matchesChildRoute = child => {
  if (!child?.to) {
    return false;
  }

  if (route.path === resolvePath(child.to) && queryMatches(child)) {
    return !child.suppressExactPathActive;
  }

  if (child.activeOn?.includes(route.name)) {
    return paramsMatch(child) && queryMatches(child);
  }

  if (Array.isArray(child.activeOn) && child.activeOn.length > 0) {
    return false;
  }

  return route.path.startsWith(resolvePath(child.to)) && queryMatches(child);
};

const isMenuItemActive = item => matchesChildRoute(item);
const isHeaderActionActive = computed(() => {
  return headerActionItem.value
    ? isMenuItemActive(headerActionItem.value)
    : false;
});

// We could use the RouterLink isActive too, but our routes are not always
// nested correctly, so we need to check the active state ourselves
// TODO: Audit the routes and fix the nesting and remove this
const activeChildren = computed(() =>
  navigableChildren.value.filter(matchesChildRoute)
);

const activeChildNames = computed(() =>
  activeChildren.value.map(child => child.name)
);

const hasActiveChild = computed(() => {
  return activeChildNames.value.length > 0;
});

const isSubGroupHeaderActive = child => {
  if (
    child?.suppressHeaderActiveWhenChildActive &&
    child?.children?.some(subChild =>
      activeChildNames.value.includes(subChild.name)
    )
  ) {
    return false;
  }

  const suppressedChildNames = child?.suppressHeaderActiveForChildren || [];

  if (
    suppressedChildNames.length > 0 &&
    suppressedChildNames.some(name => activeChildNames.value.includes(name))
  ) {
    return false;
  }

  return isMenuItemActive(child);
};

const getChildDisplayLabel = child =>
  getSidebarChildDisplayLabel(child, isExpanded.value);

const handleCollapsedClick = () => {
  if (hasChildren.value && hasAccessibleChildren.value) {
    if (props.to) {
      router.push(props.to);
      return;
    }

    const firstItem = accessibleItems.value[0];
    router.push(firstItem.to);
  }
};

const toggleTrigger = () => {
  if (
    hasAccessibleChildren.value &&
    !isExpanded.value &&
    !hasActiveChild.value
  ) {
    if (props.to) {
      router.push(props.to);
    } else {
      // if not already expanded, navigate to the first child
      const firstItem = accessibleItems.value[0];
      router.push(firstItem.to);
    }
  }
  setExpandedItem(props.name);
};

onMounted(async () => {
  await nextTick();
  if (hasActiveChild.value) {
    setExpandedItem(props.name);
  }
  window.addEventListener('blur', handleWindowBlur);
  document.addEventListener('mouseleave', handleWindowBlur);
});

onUnmounted(() => {
  window.removeEventListener('blur', handleWindowBlur);
  document.removeEventListener('mouseleave', handleWindowBlur);
});

watch(
  hasActiveChild,
  hasNewActiveChild => {
    if (hasNewActiveChild && !isExpanded.value) {
      setExpandedItem(props.name);
    }
  },
  { once: true }
);
</script>

<!-- eslint-disable-next-line vue/no-root-v-if -->
<template>
  <Policy
    v-if="!hasChildren || hasAccessibleChildren"
    :permissions="resolvePermissions(to)"
    :feature-flag="resolveFeatureFlag(to)"
    as="li"
    class="grid gap-1 text-sm cursor-pointer select-none min-w-0"
  >
    <!-- Collapsed State -->
    <template v-if="isCollapsed">
      <div
        class="relative"
        @mouseenter="handleMouseEnter"
        @mouseleave="handleMouseLeave"
      >
        <component
          :is="to && !hasChildren ? 'router-link' : 'button'"
          ref="triggerRef"
          :to="to && !hasChildren ? to : undefined"
          type="button"
          class="flex items-center justify-center size-10 rounded-lg"
          :class="{
            'text-n-slate-12 bg-n-alpha-2': isActive || hasActiveChild,
            'text-n-slate-11 hover:bg-n-alpha-2': !isActive && !hasActiveChild,
          }"
          :title="label"
          @click="hasChildren ? handleCollapsedClick() : undefined"
        >
          <Icon v-if="icon" :icon="icon" class="size-4" />
        </component>
        <SidebarCollapsedPopover
          v-if="hasChildren && isPopoverOpen"
          :label="label"
          :children="children"
          :active-child-names="activeChildNames"
          :trigger-rect="triggerRect"
          @close="closePopover"
          @mouseenter="handlePopoverMouseEnter"
          @mouseleave="handlePopoverMouseLeave"
        />
      </div>
    </template>
    <!-- Expanded State -->
    <template v-else>
      <SidebarGroupHeader
        :icon
        :name
        :label
        :to
        :getter-keys="getterKeys"
        :is-active="isActive"
        :has-active-child="hasActiveChild"
        :action-to="headerActionItem?.to"
        :action-title="headerActionItem?.label"
        :action-icon="headerActionItem?.icon"
        :action-active="isHeaderActionActive"
        :expandable="hasChildren"
        :is-expanded="isExpanded"
        @toggle="toggleTrigger"
      />
      <ul
        v-if="hasChildren"
        v-show="isExpanded || hasActiveChild"
        class="grid m-0 list-none sidebar-group-children min-w-0"
      >
        <template v-for="child in children" :key="child.name">
          <SidebarSubGroup
            v-if="child.children"
            :label="child.label"
            :icon="child.icon"
            :children="child.children"
            :is-expanded="isExpanded"
            :active-child-names="activeChildNames"
            :to="child.to"
            :header-active="isSubGroupHeaderActive(child)"
            :badge="child.badge"
            :action-label="child.actionLabel"
            :action-to="child.actionTo"
            :action-title="child.actionTitle"
            :action-icon="child.actionIcon"
            :action-items="child.actionItems"
          />
          <SidebarGroupLeaf
            v-else-if="!child.headerAction && isAllowed(child.to)"
            v-show="isExpanded || activeChildNames.includes(child.name)"
            v-bind="child"
            :label="getChildDisplayLabel(child)"
            :active="activeChildNames.includes(child.name)"
          />
        </template>
      </ul>
      <ul v-else-if="isExpandable && isExpanded">
        <SidebarGroupEmptyLeaf />
      </ul>
    </template>
  </Policy>
</template>

<style>
.sidebar-group-children .child-item::before {
  content: '';
  position: absolute;
  width: 0.125rem;
  /* 0.5px */
  height: 100%;
}

.sidebar-group-children .child-item:first-child::before {
  border-radius: 4px 4px 0 0;
}

/* This selects the last child in a group */
/* https://codepen.io/scmmishra/pen/yLmKNLW */
.sidebar-group-children > .child-item:last-child::before,
.sidebar-group-children
  > *:last-child
  > *:last-child
  > .child-item:last-child::before {
  height: 20%;
}

.sidebar-group-children > .child-item:last-child::after,
.sidebar-group-children
  > *:last-child
  > *:last-child
  > .child-item:last-child::after {
  content: '';
  position: absolute;
  width: 10px;
  height: 12px;
  bottom: calc(50% - 2px);
  border-bottom-width: 0.125rem;
  border-left-width: 0.125rem;
  border-right-width: 0px;
  border-top-width: 0px;
  border-radius: 0 0 0 4px;
  left: 0;
}

#app[dir='rtl'] .sidebar-group-children > .child-item:last-child::after,
#app[dir='rtl']
  .sidebar-group-children
  > *:last-child
  > *:last-child
  > .child-item:last-child::after {
  right: 0;
  border-bottom-width: 0.125rem;
  border-right-width: 0.125rem;
  border-left-width: 0px;
  border-top-width: 0px;
  border-radius: 0 0 4px 0px;
}
</style>
