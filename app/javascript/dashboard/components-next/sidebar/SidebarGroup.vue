<script setup>
import { computed, onMounted, onUnmounted, watch, nextTick, ref } from 'vue';
import { usePopoverState, useSidebarContext } from './provider';
import { resolveRouteConversationAssigneeType } from './sidebarActiveSelection';
import { useRoute, useRouter } from 'vue-router';
import Policy from 'dashboard/components/policy.vue';
import Icon from 'next/icon/Icon.vue';
import SidebarGroupHeader from './SidebarGroupHeader.vue';
import SidebarGroupLeaf from './SidebarGroupLeaf.vue';
import SidebarSubGroup from './SidebarSubGroup.vue';
import SidebarGroupEmptyLeaf from './SidebarGroupEmptyLeaf.vue';
import SidebarCollapsedPopover from './SidebarCollapsedPopover.vue';
import SidebarAssigneeTabs from './SidebarAssigneeTabs.vue';
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
  actionItems: { type: Array, default: () => [] },
  children: { type: Array, default: undefined },
  getterKeys: { type: Object, default: () => ({}) },
  defaultChildName: { type: String, default: '' },
  showCollapsedPopover: { type: Boolean, default: true },
  navigateOnCollapsedClick: { type: Boolean, default: true },
});

const {
  expandedItem,
  setExpandedItem,
  resolvePath,
  resolvePermissions,
  resolveFeatureFlag,
  isAllowed,
  isCollapsed,
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
      if (child.type === 'tabs') return child.items || [];
      if (!child.children) return child;
      return child.to ? [child, ...child.children] : child.children;
    }) || []
  );
});

const route = useRoute();
const router = useRouter();
const NON_ACTIVE_QUERY_KEYS = new Set(['page', 'search']);
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
  if (!props.showCollapsedPopover || !hasChildren.value) {
    return;
  }
  cancelClose();
  openPopover();
};

const handleMouseLeave = () => {
  if (!props.showCollapsedPopover || !hasChildren.value) return;
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

const defaultCollapsedRouteItem = computed(() => {
  if (props.defaultChildName) {
    const defaultItem = accessibleItems.value.find(
      child => child.name === props.defaultChildName
    );

    if (defaultItem) return defaultItem;
  }

  return accessibleItems.value[0];
});

const collapsedNavigationTarget = computed(() => {
  if (!props.navigateOnCollapsedClick) return null;

  return props.to || defaultCollapsedRouteItem.value?.to || null;
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
  const assigneeItemType = child?.name?.startsWith('Assignee:')
    ? child.name.split(':')[1]
    : null;
  const routeAssigneeType = resolveRouteConversationAssigneeType(route.query);

  if (
    assigneeItemType &&
    !Object.prototype.hasOwnProperty.call(childQuery, 'assignee_type') &&
    String(routeAssigneeType) !== String(assigneeItemType)
  ) {
    return false;
  }

  return Object.entries(childQuery).every(([key, value]) => {
    if (NON_ACTIVE_QUERY_KEYS.has(key) || typeof value === 'undefined') {
      return true;
    }

    let routeValue = route.query[key] ?? '';

    if (key === 'status') {
      routeValue = route.query[key] ?? 'open';
    }

    if (key === 'assignee_type') {
      routeValue =
        route.query.assignee_type ?? route.query.assigneeType ?? 'all';
    }

    if (key === 'crm_pipeline_id') {
      routeValue = route.query.crm_pipeline_id ?? route.query.crmPipelineId;
    }

    if (key === 'crm_stage_id') {
      routeValue = route.query.crm_stage_id ?? route.query.crmStageId;
    }

    if (key === 'appointment_status') {
      routeValue =
        route.query.appointment_status ?? route.query.appointmentStatus;
    }

    if (key === 'labels_scope') {
      routeValue = route.query.labels_scope ?? route.query.labelsScope;
    }

    if (key === 'team_scope') {
      routeValue = route.query.team_scope ?? route.query.teamScope;
    }

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
const headerActionItems = computed(() => {
  const explicitActionItems = props.actionItems.filter(
    action =>
      action.icon && (action.handler || (action.to && isAllowed(action.to)))
  );

  if (explicitActionItems.length) {
    return explicitActionItems.map(action => ({
      ...action,
      active: action.active ?? (action.to ? isMenuItemActive(action) : false),
    }));
  }

  return headerActionItem.value
    ? [
        {
          ...headerActionItem.value,
          active: isMenuItemActive(headerActionItem.value),
        },
      ]
    : [];
});

// We could use the RouterLink isActive too, but our routes are not always
// nested correctly, so we need to check the active state ourselves
// TODO: Audit the routes and fix the nesting and remove this
const routeMatchSpecificity = child => {
  const activeRouteScore = child.activeOn?.includes(route.name) ? 1000 : 0;
  const exactPathScore = route.path === resolvePath(child.to) ? 100 : 0;
  const queryScore = Object.keys(child?.to?.query || {}).length * 10;
  const paramsScore = Object.keys(child?.to?.params || {}).length * 10;

  return activeRouteScore + exactPathScore + queryScore + paramsScore;
};

const activeChildren = computed(() => {
  const matches = navigableChildren.value.filter(matchesChildRoute);
  const groupMatches = matches.filter(child => Array.isArray(child.children));
  const leafMatches = matches.filter(child => !Array.isArray(child.children));
  const activeLeaf = leafMatches.reduce((bestMatch, child) => {
    if (!bestMatch) return child;

    return routeMatchSpecificity(child) > routeMatchSpecificity(bestMatch)
      ? child
      : bestMatch;
  }, null);

  return activeLeaf ? [...groupMatches, activeLeaf] : groupMatches;
});

const activeChildNames = computed(() =>
  activeChildren.value.map(child => child.name)
);

const hasActiveChild = computed(() => {
  return activeChildNames.value.length > 0;
});

const isSubGroupHeaderActive = child => {
  if (typeof child?.active === 'boolean') {
    return child.active;
  }

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
  if (!hasChildren.value) {
    setExpandedItem(null);
    return;
  }

  if (hasChildren.value && hasAccessibleChildren.value) {
    if (expandedItem.value !== props.name) {
      setExpandedItem(props.name);
    }
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
          :is="collapsedNavigationTarget ? 'router-link' : 'button'"
          ref="triggerRef"
          :to="collapsedNavigationTarget || undefined"
          :type="collapsedNavigationTarget ? undefined : 'button'"
          class="flex items-center justify-center size-9 rounded-lg"
          :class="{
            'bg-n-brand-solid text-n-brand-contrast hover:!bg-n-brand-solid':
              isActive || hasActiveChild,
            'text-n-slate-11 hover:bg-n-alpha-2': !isActive && !hasActiveChild,
          }"
          :title="label"
          @click="handleCollapsedClick"
        >
          <Icon v-if="icon" :icon="icon" class="size-4" />
        </component>
        <SidebarCollapsedPopover
          v-if="showCollapsedPopover && hasChildren && isPopoverOpen"
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
        :actions="headerActionItems"
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
          <li
            v-if="child.type === 'section'"
            data-test="sidebar-section-label"
            class="mt-2 border-t border-n-weak px-2 pb-1 pt-3 text-[10px] font-semibold uppercase tracking-wide text-n-slate-9 first:mt-0 first:border-t-0 first:pt-1"
          >
            {{ child.label }}
          </li>
          <SidebarAssigneeTabs
            v-else-if="child.type === 'tabs'"
            v-show="
              isExpanded ||
              child.items?.some(item => activeChildNames.includes(item.name))
            "
            :items="child.items"
            :active-child-names="activeChildNames"
          />
          <SidebarSubGroup
            v-else-if="child.children"
            :label="child.label"
            :icon="child.icon"
            :children="child.children"
            :is-expanded="isExpanded"
            :active-child-names="activeChildNames"
            :to="child.to"
            :header-active="isSubGroupHeaderActive(child)"
            :badge="child.badge"
            :count="child.count"
            :action-label="child.actionLabel"
            :action-to="child.actionTo"
            :action-title="child.actionTitle"
            :action-icon="child.actionIcon"
            :action-items="child.actionItems"
            :compact-header="child.compactHeader"
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
