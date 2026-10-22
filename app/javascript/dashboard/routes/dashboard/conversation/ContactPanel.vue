<script setup>
import { computed, watch, onMounted, ref } from 'vue';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';

import AccordionItem from 'dashboard/components/Accordion/AccordionItem.vue';
import ConversationAction from './ConversationAction.vue';
import ContactInfo from './contact/ContactInfo.vue';
import ContactNotes from './contact/ContactNotes.vue';
import CustomAttributes from './customAttributes/CustomAttributes.vue';
import SharedFiles from './SharedFiles.vue';
import Draggable from 'vuedraggable';
import MacrosList from './Macros/List.vue';
import SidebarActionsHeader from 'dashboard/components-next/SidebarActionsHeader.vue';
import SchedulingPatientDetails from 'dashboard/components-next/Scheduling/SchedulingPatientDetails.vue';

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
});

const {
  updateUISettings,
  isContactSidebarItemOpen,
  conversationSidebarItemsOrder,
  toggleSidebarUIState,
} = useUISettings();

const dragging = ref(false);
const conversationSidebarItems = ref([]);

const store = useStore();
const currentChat = useMapGetter('getSelectedChat');
const attributesList = useMapGetter('attributes/getAttributes');
const attributesUIFlags = useMapGetter('attributes/getUIFlags');
const conversationId = computed(() => props.conversationId);

const channelType = computed(() => currentChat.value.meta?.channel);

const contactGetter = useMapGetter('contacts/getContact');
const contactId = computed(() => currentChat.value.meta?.sender?.id);
const contact = computed(() => contactGetter.value(contactId.value));
const detailsContactId = computed(() =>
  props.patientContextEnabled ? props.selectedPatient?.id : contactId.value
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

const onDragEnd = () => {
  dragging.value = false;
  updateUISettings({
    conversation_sidebar_items_order: conversationSidebarItems.value,
  });
};

const closeContactPanel = () => {
  updateUISettings({
    is_contact_sidebar_open: false,
    is_crm_deal_panel_open: false,
  });
};

onMounted(() => {
  conversationSidebarItems.value = conversationSidebarItemsOrder.value;
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
      <SchedulingPatientDetails
        v-if="patientContextEnabled && selectedPatient"
        :key="`${patientContextKey}:${selectedPatient.id}`"
        :patient="selectedPatient"
        :context-key="patientContextKey"
      />
      <ContactInfo
        v-else-if="!patientContextEnabled"
        :contact="contact"
        :channel-type="channelType"
      />
      <div class="px-2 pb-8 list-group">
        <Draggable
          :list="conversationSidebarItems"
          animation="200"
          ghost-class="ghost"
          handle=".drag-handle"
          item-key="name"
          class="flex flex-col gap-3"
          @start="dragging = true"
          @end="onDragEnd"
        >
          <template #item="{ element }">
            <div
              v-if="element.name === 'conversation_actions'"
              class="conversation--actions px-2 py-1 text-sm"
            >
              <ConversationAction
                :conversation-id="conversationId"
                :inbox-id="inboxId"
              />
            </div>
            <div v-else-if="element.name === 'contact_attributes'">
              <AccordionItem
                :title="$t('CONVERSATION_SIDEBAR.ACCORDION.CONTACT_ATTRIBUTES')"
                :is-open="
                  isContactSidebarItemOpen('is_contact_attributes_open')
                "
                compact
                @toggle="
                  value =>
                    toggleSidebarUIState('is_contact_attributes_open', value)
                "
              >
                <CustomAttributes
                  v-if="detailsContactId"
                  :key="detailsContactId"
                  attribute-type="contact_attribute"
                  attribute-from="conversation_contact_panel"
                  :contact-id="detailsContactId"
                  :empty-state-message="
                    $t('CONVERSATION_CUSTOM_ATTRIBUTES.NO_RECORDS_FOUND')
                  "
                />
              </AccordionItem>
            </div>
            <woot-feature-toggle
              v-else-if="element.name === 'macros'"
              feature-key="macros"
            >
              <AccordionItem
                :title="$t('CONVERSATION_SIDEBAR.ACCORDION.MACROS')"
                :is-open="isContactSidebarItemOpen('is_macro_open')"
                compact
                @toggle="value => toggleSidebarUIState('is_macro_open', value)"
              >
                <MacrosList :conversation-id="conversationId" />
              </AccordionItem>
            </woot-feature-toggle>
            <div v-else-if="element.name === 'contact_notes'">
              <AccordionItem
                :title="$t('CONVERSATION_SIDEBAR.ACCORDION.CONTACT_NOTES')"
                :is-open="isContactSidebarItemOpen('is_contact_notes_open')"
                compact
                @toggle="
                  value => toggleSidebarUIState('is_contact_notes_open', value)
                "
              >
                <ContactNotes
                  v-if="detailsContactId"
                  :key="detailsContactId"
                  :contact-id="detailsContactId"
                />
              </AccordionItem>
            </div>
            <div v-else-if="element.name === 'shared_files'">
              <AccordionItem
                :title="$t('CONVERSATION_SIDEBAR.ACCORDION.SHARED_FILES')"
                :is-open="isContactSidebarItemOpen('is_shared_files_open')"
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
