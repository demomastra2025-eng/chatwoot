<script setup>
import { computed } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';

import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import ConversationCard from 'dashboard/components-next/Conversation/ConversationCard/ConversationCard.vue';
import ContactNotificationRoute from 'dashboard/components-next/Contacts/ContactsSidebar/ContactNotificationRoute.vue';

const props = defineProps({
  sharedPhone: {
    type: Object,
    default: null,
  },
});

const { t } = useI18n();
const route = useRoute();

const conversations = useMapGetter(
  'contactConversations/getAllConversationsByContactId'
);
const contactsById = useMapGetter('contacts/getContactById');
const stateInbox = useMapGetter('inboxes/getInboxById');
const accountLabels = useMapGetter('labels/getLabels');

const accountLabelsValue = computed(() => accountLabels.value);

const uiFlags = useMapGetter('contactConversations/getUIFlags');
const isFetching = computed(() => uiFlags.value.isFetching);

const contactConversations = computed(() =>
  conversations.value(route.params.contactId)
);

// The card's own conversations only; another contact's chat that carries its notifications is linked, not listed.
const ROUTE_KINDS = [
  'own',
  'holder',
  'booking_chat',
  'appointment_contact',
  'unroutable',
];
const notificationRoute = computed(() => {
  const sharedPhone = props.sharedPhone;
  if (!sharedPhone?.patient_card) return null;
  return ROUTE_KINDS.includes(sharedPhone.route?.kind)
    ? sharedPhone.route
    : null;
});
</script>

<template>
  <div
    v-if="isFetching"
    class="flex items-center justify-center py-10 text-n-slate-11"
  >
    <Spinner />
  </div>
  <div v-else-if="notificationRoute" class="px-6 pt-4">
    <ContactNotificationRoute
      :notification-route="notificationRoute"
      :has-own-chats="contactConversations.length > 0"
    />
  </div>
  <div
    v-if="!isFetching && contactConversations.length > 0"
    class="px-6 py-4 divide-y divide-n-strong [&>*:hover]:!border-y-transparent [&>*:hover+*]:!border-t-transparent"
  >
    <ConversationCard
      v-for="conversation in contactConversations"
      :key="conversation.id"
      :conversation="conversation"
      :contact="contactsById(conversation.meta.sender.id)"
      :state-inbox="stateInbox(conversation.inboxId)"
      :account-labels="accountLabelsValue"
      class="rounded-none hover:rounded-xl hover:bg-n-alpha-1 dark:hover:bg-n-alpha-3"
    />
  </div>
  <p
    v-else-if="!isFetching && !notificationRoute"
    class="px-6 py-10 text-sm leading-6 text-center text-n-slate-11"
  >
    {{ t('CONTACTS_LAYOUT.SIDEBAR.HISTORY.EMPTY_STATE') }}
  </p>
</template>
