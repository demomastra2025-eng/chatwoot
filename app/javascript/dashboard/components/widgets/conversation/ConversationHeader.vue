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
import { conversationListReturnPath } from 'dashboard/helper/conversationListReturnContext';
import { snoozedReopenTime } from 'dashboard/helper/snoozeHelpers';
import { useInbox } from 'dashboard/composables/useInbox';
import { useI18n } from 'vue-i18n';
import {
  getCommunicationContactIdentityLabel,
  getUniqueCommunicationChannels,
  isCommunicationThread,
} from 'dashboard/helper/communicationThreadHelper';
import {
  APPOINTMENT_STATUS_ICON_CLASSES,
  APPOINTMENT_STATUS_ICONS,
} from 'dashboard/routes/dashboard/scheduling/constants';

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

  // A thread opened from the list remembers that exact list URL (folder,
  // label, team, inbox and every filter), so "back" restores the same view.
  if (name === 'communication_thread_conversation') {
    const returnPath = conversationListReturnPath({
      accountId: accountId.value,
      threadId: route.params.communication_thread_id,
    });
    if (returnPath) return returnPath;
  }

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
    assigneeType: route.query.assignee_type || route.query.assigneeType,
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

const defaultCrmPipelineName = computed(() =>
  t('CONVERSATION.HEADER.PIPELINE')
);

const crmDealStages = computed(() => {
  const stages = props.chat.crm_deal_stages || props.chat.crmDealStages || [];
  return Array.isArray(stages)
    ? stages
        .filter(stage => stage?.color)
        .map(stage => {
          const pipelineName = String(
            stage.pipeline_name || stage.pipelineName || ''
          ).trim();

          return {
            id: stage.id,
            pipelineId: stage.pipeline_id || stage.pipelineId,
            pipelineName: pipelineName || defaultCrmPipelineName.value,
            name: stage.name,
            color: stage.color,
          };
        })
    : [];
});

const APPOINTMENT_HEADER_PRIORITY = [
  'confirmed',
  'scheduled',
  'completed',
  'no_show',
  'cancelled',
];

const primaryDealStage = computed(() => crmDealStages.value[0] || null);

const extraDealsCount = computed(() =>
  Math.max(crmDealStages.value.length - 1, 0)
);

const dealsSummaryTooltip = computed(() =>
  crmDealStages.value
    .map(stage => `${stage.pipelineName}: ${stage.name}`)
    .join(' · ')
);

const schedulingAppointmentStatuses = computed(() => {
  const statuses =
    props.chat.scheduling_appointment_statuses ||
    props.chat.schedulingAppointmentStatuses ||
    [];

  return Array.isArray(statuses)
    ? statuses
        .map(statusContext => ({
          status: statusContext.status,
          count: Number(statusContext.count || 0),
        }))
        .filter(statusContext => statusContext.status)
    : [];
});

const sortedAppointmentStatuses = computed(() =>
  [...schedulingAppointmentStatuses.value].sort((left, right) => {
    const leftIdx = APPOINTMENT_HEADER_PRIORITY.indexOf(left.status);
    const rightIdx = APPOINTMENT_HEADER_PRIORITY.indexOf(right.status);
    return (leftIdx === -1 ? 99 : leftIdx) - (rightIdx === -1 ? 99 : rightIdx);
  })
);

const primaryAppointmentStatus = computed(
  () => sortedAppointmentStatuses.value[0] || null
);

const totalAppointmentsCount = computed(() =>
  schedulingAppointmentStatuses.value.reduce(
    (sum, item) => sum + Math.max(Number(item.count || 0), 1),
    0
  )
);

const extraAppointmentsCount = computed(() =>
  Math.max(totalAppointmentsCount.value - 1, 0)
);

const hasHeaderContext = computed(() =>
  Boolean(primaryDealStage.value || primaryAppointmentStatus.value)
);

const appointmentStatusClass = status =>
  APPOINTMENT_STATUS_ICON_CLASSES[status] || 'text-n-slate-11';

const appointmentStatusIcon = status =>
  APPOINTMENT_STATUS_ICONS[status] || APPOINTMENT_STATUS_ICONS.scheduled;

const appointmentStatusLabels = computed(() => ({
  cancelled: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
  completed: t('SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.completed'),
  confirmed: t('SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.confirmed'),
  no_show: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
  scheduled: t('SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.scheduled'),
}));

const appointmentStatusLabel = status =>
  appointmentStatusLabels.value[status] || status;

const appointmentsSummaryTooltip = computed(() =>
  sortedAppointmentStatuses.value
    .map(
      item =>
        `${appointmentStatusLabel(item.status)}: ${Math.max(Number(item.count || 0), 1)}`
    )
    .join(' · ')
);

const updateSidebarPanel = panelSettings => {
  const currentUiSettings = store?.getters?.getUISettings || {};
  store?.dispatch?.('updateUISettings', {
    uiSettings: {
      ...currentUiSettings,
      ...panelSettings,
    },
  });
};

const openDealsSidebar = () =>
  updateSidebarPanel({
    is_contact_sidebar_open: false,
    is_crm_deal_panel_open: true,
    is_scheduling_appointments_panel_open: false,
  });

const openAppointmentsSidebar = () =>
  updateSidebarPanel({
    is_contact_sidebar_open: false,
    is_crm_deal_panel_open: false,
    is_scheduling_appointments_panel_open: true,
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
        <div
          data-test-id="conversation-header-title-row"
          class="flex flex-row items-center max-w-full gap-1.5 p-0 m-0"
        >
          <span
            class="min-w-0 truncate text-sm font-medium leading-tight text-n-slate-12"
          >
            {{ contactDisplayName }}
          </span>
          <span
            class="inline-flex shrink-0 items-center rounded-full px-2 py-0.5 text-[11px] font-medium leading-4 whitespace-nowrap"
            :class="statusMeta.className"
          >
            {{ statusMeta.label }}
          </span>
          <div
            v-if="hasHeaderContext"
            data-test-id="conversation-header-context-row"
            class="inline-flex min-w-0 items-center gap-1.5 overflow-hidden whitespace-nowrap"
          >
            <button
              v-if="primaryDealStage"
              type="button"
              data-test-id="conversation-header-crm-stages"
              :title="dealsSummaryTooltip"
              class="inline-flex min-w-0 items-center gap-1.5 rounded-full bg-n-alpha-1 px-2 py-0.5 text-[11px] font-medium leading-4 text-n-slate-12 ring-1 ring-inset ring-n-slate-6/20 transition-colors hover:bg-n-alpha-2 whitespace-nowrap cursor-pointer"
              @click="openDealsSidebar"
            >
              <span
                class="i-lucide-briefcase-business size-3 shrink-0 text-n-slate-10"
              />
              <span
                data-test-id="conversation-header-crm-stage-dot"
                class="size-2 shrink-0 rounded-full"
                :style="{ backgroundColor: primaryDealStage.color }"
              />
              <span class="max-w-36 truncate text-n-slate-12">
                {{ primaryDealStage.name }}
              </span>
              <span
                v-if="extraDealsCount > 0"
                data-test-id="conversation-header-crm-stages-more"
                class="shrink-0 text-[10px] font-semibold text-n-slate-10 tabular-nums"
              >
                {{ `+${extraDealsCount}` }}
              </span>
            </button>
            <button
              v-if="primaryAppointmentStatus"
              type="button"
              data-test-id="conversation-header-appointment-statuses"
              :title="appointmentsSummaryTooltip"
              class="inline-flex min-w-0 items-center gap-1 rounded-full bg-n-alpha-1 px-2 py-0.5 text-[11px] font-medium leading-4 text-n-slate-12 ring-1 ring-inset ring-n-slate-6/20 transition-colors hover:bg-n-alpha-2 whitespace-nowrap cursor-pointer"
              @click="openAppointmentsSidebar"
            >
              <span
                class="inline-flex min-w-0 items-center gap-1"
                :class="appointmentStatusClass(primaryAppointmentStatus.status)"
              >
                <span
                  class="size-3 shrink-0"
                  :class="appointmentStatusIcon(primaryAppointmentStatus.status)"
                />
                <span class="max-w-36 truncate">
                  {{ appointmentStatusLabel(primaryAppointmentStatus.status) }}
                </span>
              </span>
              <span
                v-if="extraAppointmentsCount > 0"
                data-test-id="conversation-header-appointment-statuses-more"
                class="shrink-0 text-[10px] font-semibold text-n-slate-10 tabular-nums"
              >
                {{ `+${extraAppointmentsCount}` }}
              </span>
            </button>
          </div>
          <fluent-icon
            v-if="!isHMACVerified"
            v-tooltip="$t('CONVERSATION.UNVERIFIED_SESSION')"
            size="14"
            class="text-n-amber-10 my-0 mx-0 min-w-[14px] flex-shrink-0"
            icon="warning"
          />
          <span v-if="isSnoozed" class="font-medium text-xs text-n-amber-10">
            {{ snoozedDisplayText }}
          </span>
        </div>

        <div
          v-if="visibleContactIdentities.length"
          data-test-id="conversation-header-identity-row"
          class="flex items-center gap-2 overflow-hidden text-xs conversation--header--actions text-ellipsis whitespace-nowrap"
        >
          <span
            v-for="identity in visibleContactIdentities"
            :key="identity"
            class="inline-flex items-center py-0.5 text-n-slate-11 whitespace-nowrap"
          >
            {{ identity }}
          </span>
          <span
            v-if="hiddenCommunicationContactIdentityCount"
            class="inline-flex items-center px-2 py-0.5 rounded-full bg-n-alpha-1 text-n-slate-10 whitespace-nowrap"
          >
            {{ `+${hiddenCommunicationContactIdentityCount}` }}
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
