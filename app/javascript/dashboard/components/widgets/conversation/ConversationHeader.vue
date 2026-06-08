<script setup>
import { computed, ref } from 'vue';
import { useRoute } from 'vue-router';
import { useStore } from 'vuex';
import { useElementSize } from '@vueuse/core';
import BackButton from '../BackButton.vue';
import MoreActions from './MoreActions.vue';
import Avatar from 'next/avatar/Avatar.vue';
import SLACardLabel from './components/SLACardLabel.vue';
import wootConstants from 'dashboard/constants/globals';
import { conversationListPageURL } from 'dashboard/helper/URLHelper';
import { snoozedReopenTime } from 'dashboard/helper/snoozeHelpers';
import { useInbox } from 'dashboard/composables/useInbox';
import { useI18n } from 'vue-i18n';
import {
  getCommunicationContactIdentityLabel,
  getUniqueCommunicationChannels,
  isCommunicationThread,
} from 'dashboard/helper/communicationThreadHelper';

const props = defineProps({
  chat: {
    type: Object,
    default: () => ({}),
  },
  showBackButton: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();
const store = useStore();
const route = useRoute();
const conversationHeader = ref(null);
const { width } = useElementSize(conversationHeader);
const { isAWebWidgetInbox } = useInbox();

const currentChat = computed(() => store.getters.getSelectedChat);
const accountId = computed(() => store.getters.getCurrentAccountId);

const chatMetadata = computed(() => props.chat.meta || {});
const isCommunicationThreadConversation = computed(() =>
  isCommunicationThread(props.chat)
);
const communicationChannels = computed(() =>
  getUniqueCommunicationChannels(props.chat?.channels || [])
);

const compactUniqueValues = values => {
  const uniqueValues = new Set();
  return values
    .map(value => String(value || '').trim())
    .filter(value => {
      if (!value || uniqueValues.has(value)) return false;
      uniqueValues.add(value);
      return true;
    });
};

const backButtonUrl = computed(() => {
  const {
    params: { inbox_id: inboxId, label, teamId, id: customViewId },
    name,
  } = route;

  const conversationTypeMap = {
    conversation_through_mentions: 'mention',
    conversation_through_participating: 'participating',
    conversation_through_unattended: 'unattended',
  };
  return conversationListPageURL({
    accountId: accountId.value,
    inboxId,
    label,
    teamId,
    conversationType: conversationTypeMap[name],
    customViewId,
    status: route.query.status,
    communicationThread: name === 'communication_thread_conversation',
  });
});

const isHMACVerified = computed(() => {
  if (!isAWebWidgetInbox.value) {
    return true;
  }
  return chatMetadata.value.hmac_verified;
});

const currentContact = computed(() => {
  const sender = props.chat.meta?.sender || {};
  const storedContact = sender.id
    ? store.getters['contacts/getContact'](sender.id)
    : null;
  return storedContact?.id ? storedContact : sender || {};
});

const contactDisplayName = computed(() => {
  const contact = currentContact.value || props.chat.meta?.sender || {};
  return (
    contact.name ||
    contact.email ||
    contact.phone_number ||
    contact.identifier ||
    t('CONVERSATION.VOICE_WIDGET.UNKNOWN_CALLER')
  );
});

const communicationContactIdentityLabels = computed(() => {
  const contact = currentContact.value || props.chat.meta?.sender || {};
  const contactIdentityValues = [
    contact.phone_number,
    contact.email,
    contact.identifier,
  ];
  const channelIdentityValues = communicationChannels.value.map(
    getCommunicationContactIdentityLabel
  );

  return compactUniqueValues([
    ...contactIdentityValues,
    ...channelIdentityValues,
  ]).filter(value => value !== contactDisplayName.value);
});

const directContactIdentityLabels = computed(() => {
  const contact = currentContact.value || props.chat.meta?.sender || {};
  const contactInbox =
    props.chat.meta?.contact_inbox || props.chat.contact_inbox || {};
  const contactInboxIdentity = getCommunicationContactIdentityLabel({
    source_id: contactInbox.source_id,
    contact_source_id: contactInbox.source_id,
    channel_profile:
      contactInbox.channel_profile || contactInbox.channelProfile,
  });

  return compactUniqueValues([
    contact.phone_number,
    contact.email,
    contact.identifier,
    contactInboxIdentity,
  ]).filter(value => value !== contactDisplayName.value);
});

const contactIdentityLabels = computed(() =>
  isCommunicationThreadConversation.value
    ? communicationContactIdentityLabels.value
    : directContactIdentityLabels.value
);

const visibleContactIdentities = computed(() =>
  contactIdentityLabels.value.slice(0, 3)
);

const hiddenCommunicationContactIdentityCount = computed(() =>
  Math.max(
    contactIdentityLabels.value.length - visibleContactIdentities.value.length,
    0
  )
);

const isSnoozed = computed(
  () => currentChat.value.status === wootConstants.STATUS_TYPE.SNOOZED
);

const snoozedDisplayText = computed(() => {
  const { snoozed_until: snoozedUntil } = currentChat.value;
  if (snoozedUntil) {
    return `${t('CONVERSATION.HEADER.SNOOZED_UNTIL')} ${snoozedReopenTime(snoozedUntil)}`;
  }
  return t('CONVERSATION.HEADER.SNOOZED_UNTIL_NEXT_REPLY');
});

const hasSlaPolicyId = computed(() => props.chat?.sla_policy_id);

const statusMeta = computed(() => {
  const status = currentChat.value.status;

  switch (status) {
    case wootConstants.STATUS_TYPE.PENDING:
      return {
        label: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.pending.TEXT'),
        className:
          'bg-n-violet-3 text-n-violet-9 ring-1 ring-inset ring-n-violet-6/20',
      };
    case wootConstants.STATUS_TYPE.SNOOZED:
      return {
        label: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.snoozed.TEXT'),
        className:
          'bg-n-slate-3 text-n-slate-11 ring-1 ring-inset ring-n-slate-6/20',
      };
    case wootConstants.STATUS_TYPE.RESOLVED:
      return {
        label: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.resolved.TEXT'),
        className:
          'bg-n-teal-3 text-n-teal-11 ring-1 ring-inset ring-n-teal-6/20',
      };
    case wootConstants.STATUS_TYPE.OPEN:
    default:
      return {
        label: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.open.TEXT'),
        className:
          'bg-n-blue-3 text-n-blue-11 ring-1 ring-inset ring-n-blue-6/20',
      };
  }
});
</script>

<template>
  <div
    ref="conversationHeader"
    class="flex flex-col gap-3 items-center justify-between flex-1 w-full min-w-0 xl:flex-row px-3 pt-3 pb-2 h-24 xl:h-12"
  >
    <div
      class="flex items-center justify-start w-full xl:w-auto max-w-full min-w-0 xl:flex-1"
    >
      <BackButton
        v-if="showBackButton"
        :back-url="backButtonUrl"
        class="ltr:mr-2 rtl:ml-2"
      />
      <Avatar
        :name="contactDisplayName"
        :src="currentContact.thumbnail"
        :size="32"
        :status="currentContact.availability_status"
        hide-offline-status
        rounded-full
      />
      <div
        class="flex flex-col items-start min-w-0 ml-2 overflow-hidden rtl:ml-0 rtl:mr-2"
      >
        <div class="flex flex-row items-center max-w-full gap-1 p-0 m-0">
          <span
            class="text-sm font-medium truncate leading-tight text-n-slate-12"
          >
            {{ contactDisplayName }}
          </span>
          <fluent-icon
            v-if="!isHMACVerified"
            v-tooltip="$t('CONVERSATION.UNVERIFIED_SESSION')"
            size="14"
            class="text-n-amber-10 my-0 mx-0 min-w-[14px] flex-shrink-0"
            icon="warning"
          />
        </div>

        <div
          class="flex items-center gap-2 overflow-hidden text-xs conversation--header--actions text-ellipsis whitespace-nowrap"
        >
          <template v-if="visibleContactIdentities.length">
            <span
              v-for="identity in visibleContactIdentities"
              :key="identity"
              class="inline-flex items-center px-2 py-0.5 rounded-full bg-n-alpha-1 text-n-slate-10 whitespace-nowrap"
            >
              {{ identity }}
            </span>
            <span
              v-if="hiddenCommunicationContactIdentityCount"
              class="inline-flex items-center px-2 py-0.5 rounded-full bg-n-alpha-1 text-n-slate-10 whitespace-nowrap"
            >
              {{ `+${hiddenCommunicationContactIdentityCount}` }}
            </span>
          </template>
          <span
            class="inline-flex items-center px-2 py-0.5 rounded-full font-medium whitespace-nowrap"
            :class="statusMeta.className"
          >
            {{ statusMeta.label }}
          </span>
          <span v-if="isSnoozed" class="font-medium text-n-amber-10">
            {{ snoozedDisplayText }}
          </span>
        </div>
      </div>
    </div>
    <div
      class="flex flex-row items-center justify-start xl:justify-end flex-shrink-0 gap-2 w-full xl:w-auto header-actions-wrap"
    >
      <SLACardLabel
        v-if="hasSlaPolicyId"
        :chat="chat"
        show-extended-info
        :parent-width="width"
        class="hidden md:flex"
      />
      <MoreActions :conversation-id="currentChat.id" />
    </div>
  </div>
</template>
