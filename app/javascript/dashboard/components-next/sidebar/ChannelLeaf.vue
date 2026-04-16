<script setup>
import { computed, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import Icon from 'next/icon/Icon.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import ChannelStatusIcon from './ChannelStatusIcon.vue';

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
  inbox: {
    type: Object,
    required: true,
  },
  settingsRoute: {
    type: [Object, String],
    default: '',
  },
});

const route = useRoute();
const router = useRouter();
const store = useStore();
const { t } = useI18n();
const { isAdmin } = useAdmin();
const showActionsDropdown = ref(false);
const showDeletePopup = ref(false);
const isHoveringChannel = ref(false);

const reauthorizationRequired = computed(() => {
  return props.inbox.reauthorization_required;
});

const menuItems = computed(() => [
  {
    label: t('INBOX_MGMT.SETTINGS'),
    value: 'settings',
    action: 'settings',
    icon: 'i-lucide-settings-2',
  },
  {
    label: t('INBOX_MGMT.DELETE.BUTTON_TEXT'),
    value: 'delete',
    action: 'delete',
    icon: 'i-lucide-trash',
  },
]);

const deleteConfirmText = computed(
  () => `${t('INBOX_MGMT.DELETE.CONFIRM.YES')} ${props.inbox.name}`
);

const deleteRejectText = computed(
  () => `${t('INBOX_MGMT.DELETE.CONFIRM.NO')} ${props.inbox.name}`
);

const confirmDeleteMessage = computed(
  () => `${t('INBOX_MGMT.DELETE.CONFIRM.MESSAGE')} ${props.inbox.name}?`
);

const confirmPlaceHolderText = computed(() =>
  t('INBOX_MGMT.DELETE.CONFIRM.PLACE_HOLDER', {
    inboxName: props.inbox.name,
  })
);

const closeDelete = () => {
  showDeletePopup.value = false;
};

const redirectAfterDeleteIfNeeded = async () => {
  const currentInboxId = String(route.params.inbox_id || '');

  if (currentInboxId !== String(props.inbox.id)) {
    return;
  }

  const status = route.query.status || 'open';
  await router.push({
    name: 'home',
    params: { accountId: route.params.accountId },
    query: { status },
  });
};

const confirmDeletion = async () => {
  try {
    await store.dispatch('inboxes/delete', props.inbox.id);
    await redirectAfterDeleteIfNeeded();
    useAlert(t('INBOX_MGMT.DELETE.API.SUCCESS_MESSAGE'));
  } catch (error) {
    useAlert(t('INBOX_MGMT.DELETE.API.ERROR_MESSAGE'));
  } finally {
    closeDelete();
  }
};

const handleAction = async ({ action }) => {
  showActionsDropdown.value = false;

  if (action === 'settings' && props.settingsRoute) {
    await router.push(props.settingsRoute);
    return;
  }

  if (action === 'delete') {
    showDeletePopup.value = true;
  }
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
    <div
      v-if="reauthorizationRequired"
      v-tooltip.top-end="$t('SIDEBAR.REAUTHORIZE')"
      class="grid place-content-center size-5 bg-n-ruby-5/60 rounded-full"
    >
      <Icon icon="i-woot-alert" class="size-3 text-n-ruby-9" />
    </div>
    <div
      v-if="isAdmin"
      v-on-clickaway="() => (showActionsDropdown = false)"
      class="relative flex items-center"
      @click.stop
    >
      <Button
        icon="i-lucide-ellipsis-vertical"
        color="slate"
        variant="ghost"
        size="xs"
        class="opacity-100 pointer-events-auto md:transition-opacity text-n-slate-10 hover:enabled:text-n-slate-12"
        :class="{
          'md:opacity-0 md:pointer-events-none':
            !isHoveringChannel && !showActionsDropdown,
          'bg-n-alpha-2': showActionsDropdown,
        }"
        @click.prevent.stop="showActionsDropdown = !showActionsDropdown"
      />
      <DropdownMenu
        v-if="showActionsDropdown"
        :menu-items="menuItems"
        class="mt-1 top-full ltr:right-0 rtl:left-0"
        @action="handleAction($event)"
      />
    </div>
    <woot-confirm-delete-modal
      v-if="isAdmin && showDeletePopup"
      v-model:show="showDeletePopup"
      :title="$t('INBOX_MGMT.DELETE.CONFIRM.TITLE')"
      :message="confirmDeleteMessage"
      :confirm-text="deleteConfirmText"
      :reject-text="deleteRejectText"
      :confirm-value="inbox.name"
      :confirm-place-holder-text="confirmPlaceHolderText"
      @on-confirm="confirmDeletion"
      @on-close="closeDelete"
    />
  </div>
</template>
