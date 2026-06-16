<script setup>
import { computed } from 'vue';
import { useRouter } from 'vue-router';
import Icon from 'next/icon/Icon.vue';
import SidebarGroupLeaf from './SidebarGroupLeaf.vue';
import SidebarSubGroup from './SidebarSubGroup.vue';
import SidebarAssigneeTabs from './SidebarAssigneeTabs.vue';
import { useSidebarContext } from './provider';
import { getSidebarChildDisplayLabel } from './sidebarDisplayLabels';

const props = defineProps({
  label: { type: String, required: true },
  icon: { type: [String, Object, Function], default: '' },
  children: { type: Array, default: () => [] },
  activeChildNames: { type: Array, default: () => [] },
  actionTo: { type: [Object, String], default: '' },
  actionTitle: { type: String, default: '' },
  actionIcon: { type: [String, Object], default: '' },
});

defineOptions({ inheritAttrs: false });

const router = useRouter();
const { isAllowed, resolveFeatureFlag, resolvePermissions } =
  useSidebarContext();

const isSidebarActionAllowed = to => {
  if (!to) return false;

  return isAllowed(to) || !!resolveFeatureFlag(to) || !!resolvePermissions(to);
};

const headerAction = computed(() => {
  if (
    props.actionTo &&
    props.actionIcon &&
    isSidebarActionAllowed(props.actionTo)
  ) {
    return {
      to: props.actionTo,
      label: props.actionTitle,
      icon: props.actionIcon,
    };
  }

  return (
    props.children.find(
      child =>
        child.headerAction && child.to && isSidebarActionAllowed(child.to)
    ) || null
  );
});

const hasHeaderAction = computed(() => !!headerAction.value?.to);

const getChildDisplayLabel = child => getSidebarChildDisplayLabel(child, true);

const isSubGroupHeaderActive = child => {
  if (
    child?.suppressHeaderActiveWhenChildActive &&
    child?.children?.some(subChild =>
      props.activeChildNames.includes(subChild.name)
    )
  ) {
    return false;
  }

  const suppressedChildNames = child?.suppressHeaderActiveForChildren || [];

  if (
    suppressedChildNames.length > 0 &&
    suppressedChildNames.some(name => props.activeChildNames.includes(name))
  ) {
    return false;
  }

  return props.activeChildNames.includes(child.name);
};

const openHeaderAction = async () => {
  if (!headerAction.value?.to) return;
  await router.push(headerAction.value.to);
};
</script>

<template>
  <section
    class="sidebar-secondary-column hidden md:flex h-full w-[158px] flex-shrink-0 flex-col border-n-weak bg-n-background ltr:border-l rtl:border-r"
  >
    <header
      class="flex h-14 flex-shrink-0 items-center justify-between gap-2 border-b border-n-weak px-3"
    >
      <div class="flex min-w-0 items-center gap-2">
        <Icon v-if="icon" :icon="icon" class="size-5 flex-shrink-0" />
        <h2 class="m-0 min-w-0 truncate text-sm font-medium text-n-slate-12">
          {{ label }}
        </h2>
      </div>
      <button
        v-if="hasHeaderAction"
        type="button"
        class="inline-flex h-7 w-8 flex-shrink-0 items-center justify-center rounded-lg text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12"
        :title="headerAction.label"
        @click="openHeaderAction"
      >
        <Icon :icon="headerAction.icon" class="size-5" />
      </button>
    </header>
    <nav class="min-h-0 flex-1 overflow-y-auto px-2 py-2 no-scrollbar">
      <ul class="grid m-0 list-none min-w-0">
        <template v-for="(child, index) in children" :key="child.name">
          <li v-if="child.children && index > 0" class="my-1 h-px bg-n-weak" />
          <SidebarAssigneeTabs
            v-if="child.type === 'tabs'"
            :items="child.items"
            :active-child-names="activeChildNames"
          />
          <SidebarSubGroup
            v-else-if="child.children"
            :label="child.label"
            :icon="child.icon"
            :children="child.children"
            is-expanded
            :active-child-names="activeChildNames"
            :to="child.to"
            :header-active="isSubGroupHeaderActive(child)"
            :badge="child.badge"
            :action-label="child.actionLabel"
            :action-to="child.actionTo"
            :action-title="child.actionTitle"
            :action-icon="child.actionIcon"
            :action-items="child.actionItems"
            :footer-action-items="child.footerActionItems"
            :compact-header="child.compactHeader"
          />
          <SidebarGroupLeaf
            v-else-if="!child.headerAction && isAllowed(child.to)"
            v-bind="child"
            :label="getChildDisplayLabel(child)"
            :active="activeChildNames.includes(child.name)"
          />
        </template>
      </ul>
    </nav>
  </section>
</template>

<style scoped>
.sidebar-secondary-column :deep(.child-item) {
  margin-left: 0 !important;
  margin-right: 0 !important;
  padding-left: 0 !important;
  padding-right: 0 !important;
}

.sidebar-secondary-column :deep(.sidebar-group-separator) {
  gap: 0.25rem;
  padding-left: 0.25rem;
  padding-right: 0.25rem;
}
</style>
