<script setup>
import { computed, ref } from 'vue';
import Icon from 'next/icon/Icon.vue';
import SidebarUnreadBadge from 'dashboard/components-next/sidebar/SidebarUnreadBadge.vue';
import {
  CHANNEL_ICON_NEUTRAL_CLASS,
  getInboxIconByType,
} from 'dashboard/helper/inbox';

const props = defineProps({
  items: {
    type: Array,
    default: () => [],
  },
  activeKey: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['select']);
const isOpen = ref(false);

const visibleItems = computed(() =>
  props.items.filter(item => item?.key && item?.label)
);

const activeItem = computed(() =>
  visibleItems.value.find(item => item.key === props.activeKey)
);

const triggerItem = computed(() => activeItem.value || visibleItems.value[0]);

const withoutNeutralChannelColor = icon =>
  icon?.replace(CHANNEL_ICON_NEUTRAL_CLASS, '').trim() || '';

const itemIcon = item => {
  const icon = item?.inbox
    ? getInboxIconByType(item.inbox.channel_type, item.inbox.medium, 'line')
    : item?.icon || 'i-lucide-mailbox';

  return withoutNeutralChannelColor(icon);
};

const itemBadge = item => Number(item?.badge ?? 0);

const toggleDropdown = () => {
  isOpen.value = !isOpen.value;
};

const closeDropdown = () => {
  isOpen.value = false;
};

const selectItem = item => {
  closeDropdown();
  if (!item || item.key === props.activeKey) return;
  emit('select', item);
};
</script>

<template>
  <div
    v-show="visibleItems.length > 0"
    v-on-clickaway="closeDropdown"
    class="relative min-w-0 shrink"
    data-test-id="chat-list-channel-filter"
  >
    <button
      type="button"
      class="flex h-8 max-w-full min-w-0 items-center gap-1.5 rounded-lg py-0 text-[15px] font-medium leading-5 text-n-slate-12 transition-colors duration-150 ltr:pl-1 ltr:pr-1.5 rtl:pl-1.5 rtl:pr-1 hover:bg-n-alpha-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-n-brand"
      :aria-label="$t('CONVERSATION.COMMUNICATION_THREAD.ALL_CHANNELS')"
      :aria-expanded="isOpen"
      aria-haspopup="menu"
      data-test-id="chat-list-channel-filter-trigger"
      @click="toggleDropdown"
      @keydown.escape.stop.prevent="closeDropdown"
    >
      <span class="grid size-4 shrink-0 place-content-center text-current">
        <Icon :icon="itemIcon(triggerItem)" class="size-5" />
      </span>
      <span class="min-w-0 max-w-[9rem] truncate text-left rtl:text-right">
        {{ triggerItem?.label }}
      </span>
      <SidebarUnreadBadge
        :value="itemBadge(triggerItem)"
        data-test-id="chat-list-channel-filter-trigger-count"
      />
      <Icon
        icon="i-lucide-chevron-down"
        class="size-3.5 shrink-0 text-n-slate-10 transition-transform duration-150"
        :class="{ 'rotate-180': isOpen }"
      />
    </button>

    <div
      v-if="isOpen"
      class="absolute z-40 mt-1 w-64 rounded-xl bg-n-alpha-3 p-1.5 shadow-lg outline outline-1 -outline-offset-1 outline-n-weak backdrop-blur-[100px] ltr:left-0 rtl:right-0"
      role="menu"
      data-test-id="chat-list-channel-filter-menu"
    >
      <button
        v-for="item in visibleItems"
        :key="item.key"
        type="button"
        class="flex h-8 w-full items-center gap-2 rounded-lg px-2 text-left text-sm text-n-slate-11 transition-colors duration-150 hover:bg-n-alpha-2 hover:text-n-slate-12 rtl:text-right"
        :class="{
          'bg-n-alpha-2 text-n-slate-12': item.key === activeKey,
        }"
        role="menuitemradio"
        :aria-checked="item.key === activeKey"
        @click="selectItem(item)"
      >
        <span class="grid size-4 shrink-0 place-content-center text-n-slate-11">
          <Icon :icon="itemIcon(item)" class="size-4" />
        </span>
        <span class="min-w-0 flex-1 truncate">{{ item.label }}</span>
        <SidebarUnreadBadge
          :value="itemBadge(item)"
          data-test-id="chat-list-channel-filter-item-count"
        />
      </button>
    </div>
  </div>
</template>
