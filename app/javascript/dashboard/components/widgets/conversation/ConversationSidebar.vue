<script setup>
import { computed, defineAsyncComponent } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useMapGetter } from 'dashboard/composables/store';
import {
  patientContactId,
  patientDisplayName,
} from 'dashboard/stores/scheduling/patientContext';
import { useConversationPatientContext } from 'dashboard/composables/useConversationPatientContext';
import { useConversationSidepanelAvailability } from 'dashboard/composables/useConversationSidepanelAvailability';
import { vOnClickOutside } from '@vueuse/components';

const props = defineProps({
  currentChat: {
    required: true,
    type: Object,
  },
});
const ContactPanel = defineAsyncComponent(
  () => import('dashboard/routes/dashboard/conversation/ContactPanel.vue')
);
const CrmConversationDealsSidebar = defineAsyncComponent(
  () => import('dashboard/components-next/CRM/CrmConversationDealsSidebar.vue')
);
const CrmContactTasksSidebar = defineAsyncComponent(
  () => import('dashboard/components-next/CRM/CrmContactTasksSidebar.vue')
);
const SchedulingConversationAppointmentsSidebar = defineAsyncComponent(
  () =>
    import(
      'dashboard/components-next/Scheduling/SchedulingConversationAppointmentsSidebar.vue'
    )
);

const { activePanel, closePanel, isSmallScreen } =
  useConversationSidepanelAvailability();
const route = useRoute();
const router = useRouter();
const currentAccountId = useMapGetter('getCurrentAccountId');
const currentUser = useMapGetter('getCurrentUser');
const getContact = useMapGetter('contacts/getContact');
// A person without a dialog: only what belongs to the person is shown, nothing that belongs to a conversation.
const isDraft = computed(() => Boolean(props.currentChat?.is_draft));
const {
  patientStore,
  chatContactId,
  patientContextKey,
  patientContextEnabled,
  patientEntry,
  selectedPatient,
} = useConversationPatientContext({
  chat: computed(() => props.currentChat),
  accountId: currentAccountId,
  userId: computed(() => currentUser.value?.id),
  route,
  router,
});
const activeTaskContactId = computed(
  () => patientContactId(selectedPatient.value?.id) || chatContactId.value
);
const taskContact = computed(
  () =>
    getContact?.value?.(activeTaskContactId.value) ||
    (activeTaskContactId.value &&
    Number(activeTaskContactId.value) !== Number(chatContactId.value)
      ? {
          id: activeTaskContactId.value,
          name: patientDisplayName(selectedPatient.value),
        }
      : props.currentChat?.meta?.sender || {})
);
const clickOutsideOptions = {
  ignore: [
    '[data-modal-safe-interaction]',
    'dialog[open]',
    '.dashboard-combobox-dropdown',
    '.reka-date-time-picker__content',
    '.reka-color-picker__content',
  ],
};

// Contact, deals and appointments come from the shared availability rules.
const activeTab = computed(() => activePanel.value || null);
const sidebarSizeClass =
  'max-w-sm md:w-[320px] md:min-w-[320px] 2xl:min-w-[360px] 2xl:w-[360px]';
const activeReplyChannel = computed(
  () => props.currentChat?.active_reply_channel || {}
);
const activeConversationId = computed(() => {
  // A person without a dialog has no conversation: the id of the screen ('draft-5') must not reach any request.
  if (isDraft.value) return '';
  return (
    activeReplyChannel.value?.conversation_id ||
    props.currentChat?.active_reply_channel_conversation_id ||
    props.currentChat?.conversation_ids?.[0] ||
    props.currentChat?.id
  );
});
const activeInboxId = computed(
  () =>
    activeReplyChannel.value?.inbox_id ||
    props.currentChat?.active_reply_channel_inbox_id ||
    props.currentChat?.inbox_id
);
const patientConversationDisplayId = computed(
  () =>
    activeReplyChannel.value?.conversation_id ||
    props.currentChat?.active_reply_channel_conversation_id ||
    props.currentChat?.conversation_ids?.[0] ||
    (props.currentChat?.is_communication_thread ? null : props.currentChat?.id)
);
const refreshBoundPatient = async appointment => {
  const key = patientContextKey.value;
  const account = patientContactId(currentAccountId.value);
  const owner = patientContactId(chatContactId.value);
  const patientId = patientContactId(
    appointment?.patientContextContactId ||
      appointment?.patient_context_contact_id ||
      appointment?.patientContactId ||
      appointment?.patient_contact_id
  );
  const isCurrent = () =>
    patientContextEnabled.value &&
    key === patientContextKey.value &&
    account === patientContactId(currentAccountId.value) &&
    account === patientContactId(route.params.accountId) &&
    owner === patientContactId(chatContactId.value);
  if (
    !key ||
    !account ||
    !owner ||
    !patientId ||
    !isCurrent() ||
    patientContactId(appointment?.accountId ?? appointment?.account_id) !==
      account ||
    patientContactId(appointment?.contactId ?? appointment?.contact_id) !==
      owner
  )
    return;
  patientStore.rememberSelection(key, patientId);
  await patientStore.load(key, owner, { force: true });
};

const closeSidebar = () => {
  if (isSmallScreen.value && activePanel.value) closePanel();
};

const closeDealsSidebar = () => closePanel();
const closeTasksSidebar = () => closePanel();
const closeAppointmentsSidebar = () => closePanel();
</script>

<template>
  <div
    v-on-click-outside="[() => closeSidebar(), clickOutsideOptions]"
    class="bg-n-surface-2 h-full overflow-hidden flex flex-col fixed top-0 z-40 w-full transition-transform duration-300 ease-in-out ltr:right-0 rtl:left-0 md:static ltr:border-l rtl:border-r border-n-weak shadow-lg md:shadow-none"
    :class="[
      sidebarSizeClass,
      {
        'translate-x-0': !!activeTab,
        'ltr:translate-x-full rtl:-translate-x-full pointer-events-none md:translate-x-0 md:pointer-events-auto':
          !activeTab,
        'md:flex': !!activeTab,
        'md:hidden': !activeTab,
      },
    ]"
  >
    <div class="flex flex-1 overflow-y-auto overflow-x-hidden">
      <ContactPanel
        v-if="activeTab === 'contact'"
        :conversation-id="activeConversationId"
        :inbox-id="activeInboxId"
        :selected-patient="selectedPatient"
        :patient-context-enabled="patientContextEnabled"
        :patient-context-key="patientContextKey"
        :patient-entry="patientEntry"
        :patient-conversation-display-id="patientConversationDisplayId"
      />
      <div v-if="activeTab === 'deals' && !isDraft" class="min-w-0 flex-1">
        <CrmConversationDealsSidebar
          :current-chat="currentChat"
          :selected-patient="selectedPatient"
          @close="closeDealsSidebar"
        />
      </div>
      <div v-if="activeTab === 'tasks'" class="min-w-0 flex-1">
        <CrmContactTasksSidebar
          :current-chat="currentChat"
          :contact="taskContact"
          @close="closeTasksSidebar"
        />
      </div>
      <div v-if="activeTab === 'appointments'" class="min-w-0 flex-1">
        <SchedulingConversationAppointmentsSidebar
          :current-chat="currentChat"
          :selected-patient="selectedPatient"
          :patient-context-enabled="patientContextEnabled"
          :patient-context-key="patientContextKey"
          :patient-context-loading="
            !patientEntry?.loaded || patientEntry?.loading
          "
          @patient-bound="refreshBoundPatient"
          @close="closeAppointmentsSidebar"
        />
      </div>
    </div>
  </div>
</template>
