<script setup>
import { computed, watch, onMounted, ref } from 'vue';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useConversationSidepanelAvailability } from 'dashboard/composables/useConversationSidepanelAvailability';
import { useUISettings } from 'dashboard/composables/useUISettings';

import AccordionItem from 'dashboard/components/Accordion/AccordionItem.vue';
import ContactDetailsItem from './ContactDetailsItem.vue';
import ConversationAction from './ConversationAction.vue';
import ConversationLabels from './labels/LabelBox.vue';
import ContactInfo from './contact/ContactInfo.vue';
import SharedFiles from './SharedFiles.vue';
import Draggable from 'vuedraggable';
import SidebarActionsHeader from 'dashboard/components-next/SidebarActionsHeader.vue';
import SchedulingPatientDetails from 'dashboard/components-next/Scheduling/SchedulingPatientDetails.vue';
import SchedulingConversationPatientSelector from 'dashboard/components-next/Scheduling/SchedulingConversationPatientSelector.vue';

const props = defineProps({
  conversationId: {
    type: [Number, String],
    required: true,
  },
  inboxId: {
    type: Number,
    default: undefined,
  },
  selectedPatient: { type: Object, default: null },
  patientContextEnabled: { type: Boolean, default: false },
  patientContextKey: { type: String, default: '' },
  patientEntry: { type: Object, default: null },
  patientConversationDisplayId: { type: [Number, String], default: null },
});

const { closePanel } = useConversationSidepanelAvailability();

const {
  updateUISettings,
  isContactSidebarItemOpen,
  conversationSidebarItemsOrder,
  toggleSidebarUIState,
} = useUISettings();
const dragging = ref(false);
const conversationSidebarItems = ref([]);
const showPatientSummary = computed(
  () => props.patientContextEnabled && Boolean(props.selectedPatient)
);
const hasFamilyTabs = computed(
  () => (props.patientEntry?.patients?.length || 0) > 1
);

const store = useStore();
const currentChat = useMapGetter('getSelectedChat');
const attributesList = useMapGetter('attributes/getAttributes');
const attributesUIFlags = useMapGetter('attributes/getUIFlags');
const conversationId = computed(() => props.conversationId);
// A person without a dialog has no conversation to act on, no macros to run on it and no files shared in it yet.
const isDraft = computed(() => Boolean(currentChat.value?.is_draft));

const channelType = computed(() => currentChat.value.meta?.channel);

const contactGetter = useMapGetter('contacts/getContact');
const contactId = computed(() => currentChat.value.meta?.sender?.id);
const contact = computed(() => contactGetter.value(contactId.value));
const detailsContactId = computed(() =>
  props.patientContextEnabled && props.selectedPatient?.id
    ? props.selectedPatient.id
    : contactId.value
);

const getContactDetails = () => {
  if (contactId.value) {
    store.dispatch('contacts/show', { id: contactId.value });
  }
};

watch(contactId, (newContactId, prevContactId) => {
  if (newContactId && newContactId !== prevContactId) {
    getContactDetails();
  }
});
watch(
  detailsContactId,
  id => {
    if (
      props.patientContextEnabled &&
      id &&
      Number(id) !== Number(contactId.value)
    ) {
      store.dispatch('contacts/show', { id });
    }
  },
  { immediate: true }
);

const syncSidebarItems = () => {
  conversationSidebarItems.value = conversationSidebarItemsOrder.value.filter(
    item =>
      ![
        'conversation_actions',
        'contact_notes',
        'contact_attributes',
        'macros',
      ].includes(item.name)
  );
};

watch(conversationSidebarItemsOrder, () => {
  if (!dragging.value) {
    syncSidebarItems();
  }
});

const closeContactPanel = () =>
  closePanel({ is_contact_sidebar_open: false, is_crm_deal_panel_open: false });
const onDragEnd = () => {
  dragging.value = false;
  updateUISettings({
    conversation_sidebar_items_order: [
      { name: 'conversation_actions' },
      ...conversationSidebarItems.value,
    ],
  });
};

onMounted(() => {
  syncSidebarItems();
  getContactDetails();
  if (!attributesList.value?.length && !attributesUIFlags.value?.isFetching) {
    store.dispatch('attributes/get', 0);
  }
});
</script>

<template>
  <div class="flex h-full w-full min-w-0 flex-1 flex-col">
    <SidebarActionsHeader
      :title="$t('CONVERSATION.SIDEBAR.CONTACT')"
      @close="closeContactPanel"
    />
    <div
      class="flex min-h-0 min-w-0 flex-1 flex-col overflow-y-auto overflow-x-hidden"
    >
      <slot name="after-header" />
      <ContactInfo
        :contact="contact"
        :channel-type="channelType"
        :selected-patient="selectedPatient"
        :patient-context-enabled="patientContextEnabled"
      >
        <template #after-channels>
          <SchedulingConversationPatientSelector
            v-if="
              patientContextEnabled &&
              patientContextKey &&
              patientEntry?.loaded &&
              hasFamilyTabs
            "
            chips
            :show-add-button="false"
            :show-chips="hasFamilyTabs"
            :context-key="patientContextKey"
            :entry="patientEntry"
            :conversation-display-id="patientConversationDisplayId"
          />
          <SchedulingPatientDetails
            v-if="showPatientSummary && hasFamilyTabs"
            :key="`${patientContextKey}:${selectedPatient.id}:family`"
            :patient="selectedPatient"
            :context-key="patientContextKey"
            :show-name="false"
            summary
          />
        </template>
        <div
          v-if="!isDraft"
          class="flex flex-col pt-0.5"
          data-test="contact-panel-tags"
        >
          <ContactDetailsItem
            compact
            :title="$t('CONTACT_PANEL.LABELS_LABEL')"
          />
          <ConversationLabels :conversation-id="conversationId" />
        </div>
      </ContactInfo>
      <div v-if="!isDraft" class="border-t border-n-weak px-4 py-3">
        <ConversationAction
          :conversation-id="conversationId"
          :inbox-id="inboxId"
        />
      </div>
      <div class="px-2 pt-1 pb-8 list-group">
        <Draggable
          :list="conversationSidebarItems"
          animation="200"
          ghost-class="ghost"
          handle=".drag-handle"
          item-key="name"
          class="flex flex-col gap-2"
          @start="dragging = true"
          @end="onDragEnd"
        >
          <template #item="{ element }">
            <div v-if="element.name === 'shared_files' && !isDraft">
              <AccordionItem
                :title="$t('CONVERSATION_SIDEBAR.ACCORDION.SHARED_FILES')"
                :is-open="isContactSidebarItemOpen('is_shared_files_open')"
                icon="attach"
                compact
                @toggle="
                  value => toggleSidebarUIState('is_shared_files_open', value)
                "
              >
                <SharedFiles
                  v-if="isContactSidebarItemOpen('is_shared_files_open')"
                />
              </AccordionItem>
            </div>
          </template>
        </Draggable>
      </div>
    </div>
  </div>
</template>

<style lang="scss" scoped>
::v-deep {
  .contact--profile {
    @apply pb-3;
  }
}
</style>
