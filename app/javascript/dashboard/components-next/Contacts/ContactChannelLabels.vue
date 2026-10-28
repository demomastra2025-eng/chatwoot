<script setup>
import { computed, onBeforeUnmount, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { getInboxIconByType } from 'dashboard/helper/inbox';
import { copyTextToClipboard } from 'shared/helpers/clipboard';

const props = defineProps({
  contactInboxes: {
    type: Array,
    default: () => [],
  },
  existingConversationInboxIds: {
    type: Array,
    default: null,
  },
  title: {
    type: String,
    default: '',
  },
  copyOnClick: {
    type: Boolean,
    default: true,
  },
  iconOnly: { type: Boolean, default: false },
});

const emit = defineEmits(['select']);

const { t } = useI18n();
const openGroup = ref('');
let longPressTimer;
let ignoreNextClick = false;

const channelName = (channelType, medium) => {
  if (medium === 'whatsapp' || /whatsapp/i.test(channelType)) return 'WhatsApp';
  if (/telegram/i.test(channelType)) return 'Telegram';
  if (/instagram/i.test(channelType)) return 'Instagram';
  if (/facebook/i.test(channelType)) return 'Facebook';
  if (/webwidget/i.test(channelType)) return t('CONTACT_PANEL.CHANNEL_WEB');
  if (/voice/i.test(channelType)) return t('CONTACT_PANEL.CHANNEL_CALLS');
  if (/email/i.test(channelType)) return 'Email';
  if (/api/i.test(channelType)) return 'API';
  return t('CONTACT_PANEL.CHANNEL_OTHER');
};

const readableIdentifier = sourceId => {
  const value = String(sourceId || '').trim();
  return /^(\+?[\d\s()-]{7,}|@[\w.]+|[^\s@]+@[^\s@]+\.[^\s@]+)$/.test(value)
    ? value
    : '';
};

const existingConversationInboxIdSet = computed(() => {
  if (!Array.isArray(props.existingConversationInboxIds)) {
    return null;
  }

  return new Set(
    props.existingConversationInboxIds.map(inboxId => Number(inboxId))
  );
});

const channelLabels = computed(() => {
  return (props.contactInboxes || [])
    .map(contactInbox => {
      const inbox = contactInbox?.inbox || {};
      const inboxId = Number(inbox?.id || 0);
      const sourceId = contactInbox?.sourceId || contactInbox?.source_id || '';
      const channelType = inbox?.channelType || inbox?.channel_type || '';
      const medium = inbox?.medium || '';
      const brand = channelName(channelType, medium);
      const willCreateNewConversation =
        !!existingConversationInboxIdSet.value &&
        !!inboxId &&
        !existingConversationInboxIdSet.value.has(inboxId);

      return {
        id: `${inbox?.id || channelType || 'channel'}-${sourceId}`,
        inboxId: inbox?.id || null,
        sourceId,
        inboxName: inbox?.name || '',
        brand,
        label: [brand, inbox?.name, readableIdentifier(sourceId)]
          .filter(Boolean)
          .join(' · '),
        icon: getInboxIconByType(channelType, medium, 'line'),
        willCreateNewConversation,
      };
    })
    .filter(channelLabel => channelLabel.inboxId || channelLabel.sourceId)
    .sort((left, right) => {
      if (left.willCreateNewConversation !== right.willCreateNewConversation) {
        return (
          Number(left.willCreateNewConversation) -
          Number(right.willCreateNewConversation)
        );
      }

      return `${left.inboxName}:${left.sourceId}`.localeCompare(
        `${right.inboxName}:${right.sourceId}`
      );
    });
});

const channelGroups = computed(() => {
  const groups = new Map();
  channelLabels.value.forEach(channel => {
    if (!groups.has(channel.brand)) {
      groups.set(channel.brand, {
        brand: channel.brand,
        icon: channel.icon,
        channels: [],
      });
    }
    groups.get(channel.brand).channels.push(channel);
  });
  return [...groups.values()];
});

const toggleGroup = brand => {
  if (ignoreNextClick) {
    ignoreNextClick = false;
    return;
  }
  openGroup.value = openGroup.value === brand ? '' : brand;
};
const startLongPress = brand => {
  clearTimeout(longPressTimer);
  ignoreNextClick = false;
  longPressTimer = setTimeout(() => {
    openGroup.value = brand;
    ignoreNextClick = true;
  }, 450);
};
const stopLongPress = () => clearTimeout(longPressTimer);
onBeforeUnmount(stopLongPress);

const handleChannelIdentityClick = async channelLabel => {
  emit('select', channelLabel);
  if (!props.copyOnClick) return;

  await copyTextToClipboard(channelLabel.sourceId);
  useAlert(t('CONTACT_PANEL.COPY_SUCCESSFUL'));
};
</script>

<template>
  <div v-show="channelLabels.length" class="flex flex-col w-full gap-2">
    <span v-if="title" class="text-sm font-medium text-n-slate-10">
      {{ title }}
    </span>
    <div
      v-if="iconOnly"
      class="flex w-full flex-nowrap gap-1"
      data-test="channel-icons"
    >
      <div
        v-for="group in channelGroups"
        :key="group.brand"
        class="group relative shrink-0"
        data-test="channel-group"
      >
        <button
          type="button"
          class="relative flex size-8 items-center justify-center rounded-full border border-n-weak bg-n-alpha-1 text-n-slate-12 hover:bg-n-alpha-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-brand"
          :aria-label="group.brand"
          :aria-expanded="openGroup === group.brand"
          @click="toggleGroup(group.brand)"
          @touchstart="startLongPress(group.brand)"
          @touchend="stopLongPress"
          @touchcancel="stopLongPress"
        >
          <span class="size-4" :class="group.icon" aria-hidden="true" />
          <span
            v-if="group.channels.length > 1"
            class="absolute -right-1 -top-1 flex size-4 items-center justify-center rounded-full bg-n-brand text-[10px] text-white"
            data-test="channel-count"
            >{{ group.channels.length }}</span
          >
        </button>
        <div
          class="absolute right-0 top-full z-40 mt-1 hidden w-max max-w-[min(18rem,calc(100vw-2rem))] rounded-lg border border-n-weak bg-n-solid-2 p-2 text-xs text-n-slate-12 shadow-lg group-hover:block group-focus-within:block"
          :class="{ '!block': openGroup === group.brand }"
          role="tooltip"
          data-test="channel-tooltip"
        >
          <p
            v-for="channel in group.channels"
            :key="channel.id"
            class="m-0 break-words py-0.5"
          >
            {{ channel.label }}
          </p>
        </div>
      </div>
    </div>
    <div v-else class="flex flex-wrap gap-2">
      <button
        v-for="channelLabel in channelLabels"
        :key="channelLabel.id"
        type="button"
        class="inline-flex max-w-full items-center gap-2 rounded-full border border-n-weak bg-n-slate-9/10 px-2.5 py-1 text-xs text-n-slate-12 shadow-sm transition-colors hover:border-n-slate-4 hover:bg-n-alpha-1"
        :class="channelLabel.willCreateNewConversation ? 'border-dashed' : ''"
        :title="channelLabel.label"
        @click="handleChannelIdentityClick(channelLabel)"
      >
        <span class="size-3.5 flex-shrink-0" :class="channelLabel.icon" />
        <span class="max-w-[14rem] truncate">
          {{ channelLabel.label }}
        </span>
      </button>
    </div>
  </div>
</template>
