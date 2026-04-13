<script setup>
import { computed } from 'vue';
import { useToggle } from '@vueuse/core';
import { useI18n } from 'vue-i18n';
import { dynamicTime } from 'shared/helpers/timeHelper';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Policy from 'dashboard/components/policy.vue';

const props = defineProps({
  id: {
    type: Number,
    required: true,
  },
  name: {
    type: String,
    required: true,
  },
  description: {
    type: String,
    default: '',
  },
  transportType: {
    type: String,
    required: true,
  },
  allowedScopes: {
    type: Array,
    default: () => [],
  },
  oauthStatus: {
    type: Object,
    default: () => ({}),
  },
  updatedAt: {
    type: Number,
    required: true,
  },
  createdAt: {
    type: Number,
    required: true,
  },
});

const emit = defineEmits(['action']);
const { t } = useI18n();
const [showActionsDropdown, toggleDropdown] = useToggle();

const menuItems = computed(() => [
  {
    label: t('CAPTAIN.MCP_SERVERS.OPTIONS.MANAGE_SERVER'),
    value: 'manage',
    action: 'manage',
    icon: 'i-lucide-sliders-horizontal',
  },
  {
    label: t('CAPTAIN.MCP_SERVERS.OPTIONS.EDIT_SERVER'),
    value: 'edit',
    action: 'edit',
    icon: 'i-lucide-pencil-line',
  },
  {
    label: t('CAPTAIN.MCP_SERVERS.OPTIONS.DELETE_SERVER'),
    value: 'delete',
    action: 'delete',
    icon: 'i-lucide-trash',
  },
]);

const timestamp = computed(() =>
  dynamicTime(props.updatedAt || props.createdAt)
);
const scopeLabel = computed(() => {
  if (
    props.allowedScopes.includes('agent') &&
    props.allowedScopes.includes('assistant')
  ) {
    return t('CAPTAIN.MCP_SERVERS.SCOPES.BOTH');
  }

  if (props.allowedScopes.includes('assistant')) {
    return t('CAPTAIN.MCP_SERVERS.SCOPES.ASSISTANT');
  }

  return t('CAPTAIN.MCP_SERVERS.SCOPES.AGENT');
});
const oauthLabel = computed(() => {
  if (!props.oauthStatus?.configured) {
    return '';
  }

  return props.oauthStatus.connected
    ? t('CAPTAIN.MCP_SERVERS.OAUTH.CONNECTED')
    : t('CAPTAIN.MCP_SERVERS.OAUTH.NOT_CONNECTED');
});

const handleAction = ({ action, value }) => {
  toggleDropdown(false);
  emit('action', { action, value, id: props.id });
};
</script>

<template>
  <CardLayout class="relative">
    <div class="flex relative justify-between w-full gap-1">
      <div class="flex items-center gap-2 min-w-0">
        <span class="text-base text-n-slate-12 line-clamp-1 font-medium">
          {{ name }}
        </span>
        <span
          class="shrink-0 rounded-full bg-n-alpha-black2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
        >
          {{ transportType }}
        </span>
        <span
          v-if="oauthLabel"
          class="shrink-0 rounded-full px-2 py-0.5 text-xs font-medium"
          :class="
            oauthStatus.connected
              ? 'bg-n-teal-3 text-n-teal-11'
              : 'bg-n-amber-3 text-n-amber-11'
          "
        >
          {{ oauthLabel }}
        </span>
      </div>
      <Policy
        v-on-clickaway="() => toggleDropdown(false)"
        :permissions="['administrator']"
        class="relative flex items-center group"
      >
        <Button
          icon="i-lucide-ellipsis-vertical"
          color="slate"
          size="xs"
          class="rounded-md group-hover:bg-n-alpha-2"
          @click="toggleDropdown()"
        />
        <DropdownMenu
          v-if="showActionsDropdown"
          :menu-items="menuItems"
          class="mt-1 ltr:right-0 rtl:right-0 top-full"
          @action="handleAction($event)"
        />
      </Policy>
    </div>
    <div class="flex items-center justify-between w-full gap-4">
      <div class="flex items-center gap-3 flex-1 min-w-0">
        <span
          v-if="description"
          class="text-sm truncate text-n-slate-11 flex-1"
        >
          {{ description }}
        </span>
        <span class="text-sm shrink-0 text-n-slate-11">
          {{ scopeLabel }}
        </span>
      </div>
      <span class="text-sm text-n-slate-11 line-clamp-1 shrink-0">
        {{ timestamp }}
      </span>
    </div>
  </CardLayout>
</template>
