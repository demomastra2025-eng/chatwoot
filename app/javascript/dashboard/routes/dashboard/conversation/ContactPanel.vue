<script setup>
import { computed, watch, onMounted, ref } from 'vue';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useConversationSidepanelAvailability } from 'dashboard/composables/useConversationSidepanelAvailability';

import AccordionItem from 'dashboard/components/Accordion/AccordionItem.vue';
import ConversationAction from './ConversationAction.vue';
import ContactInfo from './contact/ContactInfo.vue';
import ContactNotes from './contact/ContactNotes.vue';
import ContactConversations from './ContactConversations.vue';
import CustomAttributes from './customAttributes/CustomAttributes.vue';
import SharedFiles from './SharedFiles.vue';
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

const { closePanel } = useConversationSidepanelAvailability();

const openSections = ref({});
const sectionIsOpen = key => Boolean(openSections.value[key]);
const setSectionOpen = (key, value) => {
  openSections.value = { ...openSections.value, [key]: value };
};

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

const closeContactPanel = () =>
  closePanel({ is_contact_sidebar_open: false, is_crm_deal_panel_open: false });

onMounted(() => {
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
        :patient-context-key="patientContextKey"
        :patient-context-enabled="patientContextEnabled"
      >
        <template v-if="patientContextEnabled && selectedPatient">
          <h3 class="px-4 text-sm font-semibold text-n-slate-12">
            {{ $t('CONTACT_PANEL.ABOUT_DIALOG') }}
          </h3>
          <slot name="after-profile" />
          <p class="px-4 text-xs text-n-slate-11">
            {{ $t('CONTACT_PANEL.PATIENT_HINT') }}
          </p>
          <SchedulingPatientDetails
            :key="`${patientContextKey}:${selectedPatient.id}`"
            :patient="selectedPatient"
            :context-key="patientContextKey"
            :show-name="false"
          />
        </template>
      </ContactInfo>
      <div v-if="!isDraft" class="border-t border-n-weak px-4 py-3">
        <h3 class="mb-2 text-sm font-semibold text-n-slate-12">
          {{ $t('CONTACT_PANEL.THIS_DIALOG') }}
        </h3>
        <ConversationAction
          :conversation-id="conversationId"
          :inbox-id="inboxId"
        />
      </div>
      <div class="grid gap-2 border-t border-n-weak px-4 py-3 pb-8">
        <AccordionItem
          :title="$t('CONTACT_PANEL.SECTION_NOTES')"
          :is-open="sectionIsOpen('notes')"
          compact
          @toggle="value => setSectionOpen('notes', value)"
        >
          <ContactNotes
            v-if="detailsContactId && sectionIsOpen('notes')"
            :key="detailsContactId"
            :contact-id="detailsContactId"
          />
        </AccordionItem>
        <AccordionItem
          v-if="!isDraft"
          :title="$t('CONTACT_PANEL.SECTION_HISTORY')"
          :is-open="sectionIsOpen('history')"
          compact
          @toggle="value => setSectionOpen('history', value)"
        >
          <ContactConversations
            v-if="sectionIsOpen('history') && contactId"
            :contact-id="contactId"
            :conversation-id="conversationId"
          />
        </AccordionItem>
        <AccordionItem
          v-if="!isDraft"
          :title="$t('CONTACT_PANEL.SECTION_FILES')"
          :is-open="sectionIsOpen('files')"
          compact
          @toggle="value => setSectionOpen('files', value)"
        >
          <SharedFiles v-if="sectionIsOpen('files')" />
        </AccordionItem>
        <AccordionItem
          :title="$t('CONTACT_PANEL.SECTION_ATTRIBUTES_MACROS')"
          :is-open="sectionIsOpen('attributes')"
          compact
          @toggle="value => setSectionOpen('attributes', value)"
        >
          <div v-if="sectionIsOpen('attributes')">
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
            <woot-feature-toggle v-if="!isDraft" feature-key="macros">
              <MacrosList :conversation-id="conversationId" />
            </woot-feature-toggle>
          </div>
        </AccordionItem>
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
