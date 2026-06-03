<script setup>
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAdmin } from 'dashboard/composables/useAdmin';
import Icon from 'next/icon/Icon.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ChannelStatusIcon from './ChannelStatusIcon.vue';
import SidebarUnreadBadge from './SidebarUnreadBadge.vue';

const props = defineProps({
  label: {
    type: String,
    required: true,
  },
  // eslint-disable-next-line vue/no-unused-properties
  active: {
    type: Boolean,
    default: false,
  },
  badge: {
    type: [Number, String],
    default: 0,
  },
  inbox: {
    type: Object,
    required: true,
  },
  settingsRoute: {
    type: [Object, String],
    default: '',
  },
});

const router = useRouter();
const { t } = useI18n();
const { isAdmin } = useAdmin();
const isHoveringChannel = ref(false);

const reauthorizationRequired = computed(() => {
  return props.inbox.reauthorization_required;
});

const badgeCount = computed(() => Number(props.badge) || 0);

const openSettings = async () => {
  if (!props.settingsRoute) {
    return;
  }

  await router.push(props.settingsRoute);
};

const handleMouseEnter = () => {
  isHoveringChannel.value = true;
};

const handleMouseLeave = () => {
  isHoveringChannel.value = false;
};
</script>

<template>
  <div
    class="w-full flex items-center gap-2"
    @mouseenter="handleMouseEnter"
    @mouseleave="handleMouseLeave"
  >
    <span class="size-4 grid place-content-center rounded-full">
      <ChannelStatusIcon :inbox="inbox" />
    </span>
    <div class="flex-1 truncate min-w-0">{{ label }}</div>
    <SidebarUnreadBadge :value="badgeCount" />
    <div
      v-if="reauthorizationRequired"
      v-tooltip.top-end="$t('SIDEBAR.REAUTHORIZE')"
      class="grid place-content-center size-5 bg-n-ruby-5/60 rounded-full"
    >
      <Icon icon="i-woot-alert" class="size-3 text-n-ruby-9" />
    </div>
    <div v-if="isAdmin" class="relative flex items-center" @click.stop>
      <Button
        icon="i-lucide-settings-2"
        color="slate"
        variant="ghost"
        size="xs"
        class="opacity-100 pointer-events-auto md:transition-opacity text-n-slate-10 hover:enabled:text-n-slate-12"
        :class="{
          'md:opacity-0 md:pointer-events-none': !isHoveringChannel,
        }"
        :title="t('INBOX_MGMT.SETTINGS')"
        @click.prevent.stop="openSettings"
      />
    </div>
  </div>
</template>
