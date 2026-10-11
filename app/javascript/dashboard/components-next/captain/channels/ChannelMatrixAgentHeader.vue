<script setup>
import { computed, onBeforeUnmount, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { OnClickOutside } from '@vueuse/components';

import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import { CHANNEL_SCOPES } from 'dashboard/helper/captainChannelMatrix';

// Column header of the channel matrix: the agent and where it works
// («все каналы» / «выбранные»), switched through a small menu. The menu is
// teleported to the body so the scrolling matrix block cannot clip it.

const props = defineProps({
  assistant: {
    type: Object,
    required: true,
  },
  disabled: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['update:scope']);

const { t } = useI18n();

const MENU_CLASS = 'captain-matrix-scope-menu';
const MENU_WIDTH = 248;
const MENU_GAP = 4;
const VIEWPORT_PADDING = 8;
// The teleported menu lives outside this component's DOM.
const clickOutsideOptions = { ignore: [`.${MENU_CLASS}`] };

const triggerRef = ref(null);
const isMenuOpen = ref(false);
const menuStyle = ref({});

const isAllScope = computed(
  () => props.assistant.channel_scope !== CHANNEL_SCOPES.SELECTED
);
const scopeLabel = computed(() =>
  isAllScope.value
    ? t('CAPTAIN.CHANNEL_MATRIX.SCOPE_ALL')
    : t('CAPTAIN.CHANNEL_MATRIX.SCOPE_SELECTED')
);
const agentName = computed(
  () => props.assistant.name || `#${props.assistant.id}`
);
const scopeMenuLabel = computed(() =>
  t('CAPTAIN.CHANNEL_MATRIX.SCOPE_MENU', { agent: agentName.value })
);
const menuItems = computed(() => [
  {
    label: t('CAPTAIN.CHANNEL_MATRIX.MENU_ALL'),
    value: CHANNEL_SCOPES.ALL,
    action: 'scope',
    isSelected: isAllScope.value,
  },
  {
    label: t('CAPTAIN.CHANNEL_MATRIX.MENU_SELECTED'),
    value: CHANNEL_SCOPES.SELECTED,
    action: 'scope',
    isSelected: !isAllScope.value,
  },
]);

const positionMenu = () => {
  const rect = triggerRef.value?.getBoundingClientRect?.();
  if (!rect) return;

  const width = Math.min(MENU_WIDTH, window.innerWidth - VIEWPORT_PADDING * 2);
  const centeredLeft = rect.left + rect.width / 2 - width / 2;
  const left = Math.min(
    Math.max(centeredLeft, VIEWPORT_PADDING),
    window.innerWidth - width - VIEWPORT_PADDING
  );
  menuStyle.value = {
    top: `${Math.round(rect.bottom + MENU_GAP)}px`,
    left: `${Math.round(left)}px`,
    width: `${Math.round(width)}px`,
  };
};

const closeMenu = () => {
  isMenuOpen.value = false;
  window.removeEventListener('scroll', closeMenu, true);
  window.removeEventListener('resize', closeMenu);
};

const openMenu = () => {
  if (props.disabled) return;
  positionMenu();
  isMenuOpen.value = true;
  window.addEventListener('scroll', closeMenu, true);
  window.addEventListener('resize', closeMenu);
};

const toggleMenu = () => {
  if (isMenuOpen.value) {
    closeMenu();
    return;
  }
  openMenu();
};

const selectScope = ({ value }) => {
  closeMenu();
  const currentScope = isAllScope.value
    ? CHANNEL_SCOPES.ALL
    : CHANNEL_SCOPES.SELECTED;
  if (value !== currentScope) emit('update:scope', value);
};

onBeforeUnmount(closeMenu);
</script>

<template>
  <div
    class="flex min-w-0 flex-col items-center gap-1.5 text-center"
    :data-testid="`matrix-agent-${assistant.id}`"
  >
    <Avatar
      :src="assistant.avatar_url || ''"
      :name="assistant.name || ''"
      :size="32"
      rounded-full
    />
    <span
      class="max-w-[9rem] truncate text-heading-3 text-n-slate-12"
      :class="{ 'opacity-60': !assistant.active }"
      :title="agentName"
    >
      {{ agentName }}
    </span>
    <span v-if="!assistant.active" class="text-xs text-n-slate-10">
      {{ t('CAPTAIN.CHANNEL_MATRIX.INACTIVE') }}
    </span>
    <OnClickOutside :options="clickOutsideOptions" @trigger="closeMenu">
      <span ref="triggerRef" class="inline-flex">
        <Button
          :label="scopeLabel"
          variant="ghost"
          color="slate"
          size="xs"
          icon="i-lucide-chevron-down"
          trailing-icon
          class="!text-n-slate-11"
          :disabled="disabled"
          :title="scopeMenuLabel"
          :aria-expanded="isMenuOpen"
          aria-haspopup="menu"
          data-testid="matrix-scope-trigger"
          @click="toggleMenu"
        />
      </span>
    </OnClickOutside>
    <Teleport to="body">
      <DropdownMenu
        v-if="isMenuOpen"
        :class="MENU_CLASS"
        class="!fixed"
        :style="menuStyle"
        :menu-items="menuItems"
        data-testid="matrix-scope-menu"
        @action="selectScope"
      />
    </Teleport>
  </div>
</template>
