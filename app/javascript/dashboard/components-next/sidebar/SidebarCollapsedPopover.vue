<script setup>
import { computed, ref, onMounted, nextTick } from 'vue';
import { useRouter } from 'vue-router';
import { useSidebarContext } from './provider';
import { useMapGetter } from 'dashboard/composables/store';
import Icon from 'next/icon/Icon.vue';
import TeleportWithDirection from 'dashboard/components-next/TeleportWithDirection.vue';
import SidebarUnreadBadge from './SidebarUnreadBadge.vue';
import SidebarAssigneeTabs from './SidebarAssigneeTabs.vue';

const props = defineProps({
  label: { type: String, required: true },
  children: { type: Array, default: () => [] },
  activeChildNames: { type: Array, default: () => [] },
  triggerRect: { type: Object, default: () => ({ top: 0, left: 0 }) },
});

const emit = defineEmits(['close', 'mouseenter', 'mouseleave']);

const router = useRouter();
const { isAllowed, sidebarWidth } = useSidebarContext();

const expandedSubGroup = ref(null);
const popoverRef = ref(null);
const topPosition = ref(0);
const isRTL = useMapGetter('accounts/isRTL');
const skipTransition = ref(true);

const toggleSubGroup = name => {
  expandedSubGroup.value = expandedSubGroup.value === name ? null : name;
};

const navigateAndClose = to => {
  router.push(to);
  emit('close');
};

const isActive = child => props.activeChildNames.includes(child.name);

const getAccessibleSubChildren = children =>
  children.filter(c => isAllowed(c.to));

const getAccessibleActionItems = actionItems =>
  (actionItems || []).filter(
    action => action.handler || (action.to && isAllowed(action.to))
  );

const handleActionClick = action => {
  if (action.handler) {
    action.handler();
    emit('close');
    return;
  }

  if (action.to) {
    navigateAndClose(action.to);
  }
};

const handleSubGroupClick = child => {
  if (child.to && isAllowed(child.to)) {
    navigateAndClose(child.to);
    return;
  }

  toggleSubGroup(child.name);
};

const renderIcon = icon => ({
  component: typeof icon === 'object' ? icon : Icon,
  props: typeof icon === 'string' ? { icon } : null,
});

const iconBaseClass = icon =>
  typeof icon === 'string' ? 'size-4 flex-shrink-0' : 'flex-shrink-0';

const badgeCount = item => Number(item?.badge) || 0;
const hasPlainCount = item =>
  item?.count !== null && typeof item?.count !== 'undefined';
const plainCountLabel = item => {
  const count = Number(item?.count) || 0;
  return count > 999 ? '999+' : String(count);
};

const transition = computed(() =>
  skipTransition.value
    ? {}
    : {
        enterActiveClass: 'transition-all duration-200 ease-out',
        enterFromClass: 'opacity-0 -translate-y-2 max-h-0',
        enterToClass: 'opacity-100 translate-y-0 max-h-96',
        leaveActiveClass: 'transition-all duration-150 ease-in',
        leaveFromClass: 'opacity-100 translate-y-0 max-h-96',
        leaveToClass: 'opacity-0 -translate-y-2 max-h-0',
      }
);

const accessibleChildren = computed(() => {
  return props.children.filter(child => {
    if (child.headerAction) {
      return false;
    }

    if (child.type === 'tabs') {
      return child.items?.some(item => item.to && isAllowed(item.to));
    }

    if (child.children) {
      return (
        (child.to && isAllowed(child.to)) ||
        child.children.some(subChild => isAllowed(subChild.to))
      );
    }
    return child.to && isAllowed(child.to);
  });
});

onMounted(async () => {
  await nextTick();

  // Auto-expand subgroup if active child is inside it
  if (props.activeChildNames.length) {
    const parentGroup = props.children.find(
      child =>
        props.activeChildNames.includes(child.name) ||
        child.children?.some(subChild =>
          props.activeChildNames.includes(subChild.name)
        )
    );
    if (parentGroup) {
      expandedSubGroup.value = parentGroup.name;
      // Wait for the subgroup expansion to render before measuring height
      await nextTick();
    }
  }

  if (!props.triggerRect) return;

  const viewportHeight = window.innerHeight;
  const popoverHeight = popoverRef.value?.offsetHeight || 300;
  const { top: triggerTop } = props.triggerRect;

  // Adjust position if popover would overflow viewport
  topPosition.value =
    triggerTop + popoverHeight > viewportHeight - 20
      ? Math.max(20, viewportHeight - popoverHeight - 20)
      : triggerTop;

  await nextTick();
  skipTransition.value = false;
});
</script>

<template>
  <TeleportWithDirection>
    <div
      ref="popoverRef"
      class="fixed z-[100] min-w-[200px] max-w-[280px]"
      :style="{
        [isRTL ? 'right' : 'left']: `${sidebarWidth + 8}px`,
        top: `${topPosition}px`,
      }"
      @mouseenter="emit('mouseenter')"
      @mouseleave="emit('mouseleave')"
    >
      <div
        class="bg-n-alpha-3 backdrop-blur-[100px] outline outline-1 -outline-offset-1 w-56 outline-n-weak rounded-xl shadow-lg py-2 px-2"
      >
        <div
          class="px-2 py-1.5 text-xs font-medium text-n-slate-11 uppercase tracking-wider border-b border-n-weak mb-1"
        >
          {{ label }}
        </div>
        <ul
          class="m-0 p-0 list-none max-h-[400px] overflow-y-auto no-scrollbar"
        >
          <template v-for="child in accessibleChildren" :key="child.name">
            <SidebarAssigneeTabs
              v-if="child.type === 'tabs'"
              :items="child.items"
              :active-child-names="activeChildNames"
              @select="emit('close')"
            />
            <!-- SubGroup with children -->
            <li v-else-if="child.children" class="py-0.5">
              <div
                class="flex items-center gap-1 rounded-lg transition-colors duration-150 ease-out"
                :class="{
                  'text-n-slate-12 bg-n-alpha-2': isActive(child),
                  'text-n-slate-11 hover:bg-n-alpha-2': !isActive(child),
                }"
              >
                <button
                  class="flex min-w-0 flex-1 items-center gap-2 px-2 py-1.5 text-left rtl:text-right"
                  @click="handleSubGroupClick(child)"
                >
                  <Icon
                    v-if="child.icon"
                    :icon="child.icon"
                    :class="iconBaseClass(child.icon)"
                  />
                  <span class="flex-1 truncate text-sm">{{ child.label }}</span>
                  <span
                    v-if="hasPlainCount(child)"
                    data-test-id="sidebar-plain-count"
                    class="shrink-0 text-xs font-medium leading-5 tabular-nums text-current"
                  >
                    {{ plainCountLabel(child) }}
                  </span>
                  <SidebarUnreadBadge v-else :value="badgeCount(child)" />
                </button>
                <button
                  type="button"
                  class="inline-flex flex-shrink-0 items-center justify-center rounded-md p-1 text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12"
                  :title="child.label"
                  @click.stop="toggleSubGroup(child.name)"
                >
                  <span
                    class="size-3 transition-transform i-lucide-chevron-down"
                    :class="{
                      'rotate-180': expandedSubGroup === child.name,
                    }"
                  />
                </button>
                <button
                  v-for="(action, index) in getAccessibleActionItems(
                    child.actionItems
                  )"
                  :key="action.title || action.icon || index"
                  type="button"
                  class="inline-flex flex-shrink-0 items-center justify-center rounded-md p-1 text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12 ltr:mr-1 rtl:ml-1"
                  :title="action.title"
                  @click.prevent.stop="handleActionClick(action)"
                >
                  <Icon :icon="action.icon" class="size-3.5" />
                </button>
              </div>
              <Transition v-bind="transition">
                <ul
                  v-if="expandedSubGroup === child.name"
                  class="m-0 p-0 list-none ltr:pl-4 rtl:pr-4 mt-1 overflow-hidden"
                >
                  <li
                    v-for="subChild in getAccessibleSubChildren(child.children)"
                    :key="subChild.name"
                    class="py-0.5"
                  >
                    <button
                      class="flex items-center px-2 py-1.5 w-full rounded-lg text-sm text-left rtl:text-right transition-colors duration-150 ease-out"
                      :class="[
                        {
                          'text-n-slate-12 bg-n-alpha-2': isActive(subChild),
                          'text-n-slate-11 hover:bg-n-alpha-2':
                            !isActive(subChild),
                        },
                        subChild.compactIconGap ? 'gap-1' : 'gap-2',
                      ]"
                      @click="navigateAndClose(subChild.to)"
                    >
                      <component
                        :is="renderIcon(subChild.icon).component"
                        v-if="subChild.icon"
                        v-bind="renderIcon(subChild.icon).props"
                        :class="[
                          iconBaseClass(subChild.icon),
                          subChild.iconClass,
                        ]"
                      />
                      <span
                        class="flex-1 truncate"
                        :class="subChild.labelClass"
                      >
                        {{ subChild.label }}
                      </span>
                      <span
                        v-if="hasPlainCount(subChild)"
                        data-test-id="sidebar-plain-count"
                        class="shrink-0 text-xs font-medium leading-5 tabular-nums"
                        :class="subChild.countClass || 'text-current'"
                      >
                        {{ plainCountLabel(subChild) }}
                      </span>
                      <SidebarUnreadBadge
                        v-else
                        :value="badgeCount(subChild)"
                      />
                    </button>
                  </li>
                </ul>
              </Transition>
            </li>
            <!-- Direct child item -->
            <li v-else class="py-0.5">
              <button
                class="flex items-center px-2 py-1.5 w-full rounded-lg text-sm text-left rtl:text-right transition-colors duration-150 ease-out"
                :class="[
                  {
                    'text-n-slate-12 bg-n-alpha-2': isActive(child),
                    'text-n-slate-11 hover:bg-n-alpha-2': !isActive(child),
                  },
                  child.compactIconGap ? 'gap-1' : 'gap-2',
                ]"
                @click="navigateAndClose(child.to)"
              >
                <component
                  :is="renderIcon(child.icon).component"
                  v-if="child.icon"
                  v-bind="renderIcon(child.icon).props"
                  :class="[iconBaseClass(child.icon), child.iconClass]"
                />
                <span class="flex-1 truncate" :class="child.labelClass">
                  {{ child.label }}
                </span>
                <span
                  v-if="hasPlainCount(child)"
                  data-test-id="sidebar-plain-count"
                  class="shrink-0 text-xs font-medium leading-5 tabular-nums"
                  :class="child.countClass || 'text-current'"
                >
                  {{ plainCountLabel(child) }}
                </span>
                <SidebarUnreadBadge v-else :value="badgeCount(child)" />
              </button>
            </li>
          </template>
        </ul>
      </div>
    </div>
  </TeleportWithDirection>
</template>
