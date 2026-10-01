<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';

// Option A (owner decision 2026-09-29): a patient card without its own chats shows where its notifications go. The
// other contact's chat is linked, never listed as the card's own conversation.
const props = defineProps({
  notificationRoute: {
    type: Object,
    default: null,
  },
  hasOwnChats: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();
const route = useRoute();

const VIA_CHAT_KINDS = ['holder', 'booking_chat', 'appointment_contact'];
const BOOKING_NOTE_KINDS = ['booking_chat'];

const kind = computed(() => props.notificationRoute?.kind);
const viaChat = computed(
  () =>
    VIA_CHAT_KINDS.includes(kind.value) && !!props.notificationRoute?.contact
);
const ownNumber = computed(() => kind.value === 'own');
// An appointment without a booking chat whose number has no verified phone chat: nothing is sent until staff pick
// a route (sc8rv1 round 3 H2c).
const unroutable = computed(() => kind.value === 'unroutable');
const maskedPhone = computed(() => props.notificationRoute?.masked_phone);

const viaChatText = computed(() => {
  const name = props.notificationRoute?.contact?.name || '';
  return maskedPhone.value
    ? t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.ROUTE_VIA_CHAT', {
        name,
        phone: maskedPhone.value,
      })
    : t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.ROUTE_VIA_CHAT_NO_PHONE', {
        name,
      });
});

const chatLink = computed(() => {
  const displayId = props.notificationRoute?.conversation_display_id;
  if (!displayId) return null;

  return {
    name: 'inbox_conversation',
    params: { accountId: route.params.accountId, conversation_id: displayId },
  };
});
</script>

<template>
  <div
    class="flex flex-col gap-2 p-3 text-sm rounded-xl bg-n-alpha-2 text-n-slate-12"
    data-testid="contact-notification-route"
  >
    <p v-if="!hasOwnChats" class="mb-0 text-n-slate-11">
      {{ t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.NO_OWN_CHATS') }}
    </p>
    <template v-if="viaChat">
      <p class="mb-0" data-testid="contact-notification-route-via">
        {{ viaChatText }}
      </p>
      <p
        v-if="BOOKING_NOTE_KINDS.includes(kind) && maskedPhone"
        class="mb-0 text-n-slate-11"
      >
        {{
          t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.ROUTE_BOOKING_NOTE', {
            phone: maskedPhone,
          })
        }}
      </p>
      <router-link
        v-if="chatLink"
        :to="chatLink"
        class="font-medium text-n-blue-11 hover:underline"
        data-testid="contact-notification-route-link"
      >
        {{ t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.OPEN_CHAT') }}
      </router-link>
    </template>
    <p
      v-else-if="ownNumber"
      class="mb-0"
      data-testid="contact-notification-route-own"
    >
      {{
        t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.ROUTE_OWN_NUMBER', {
          phone: maskedPhone,
        })
      }}
    </p>
    <p
      v-else-if="unroutable"
      class="mb-0 text-n-amber-11"
      data-testid="contact-notification-route-unroutable"
    >
      {{
        t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.ROUTE_UNROUTABLE', {
          phone: maskedPhone,
        })
      }}
    </p>
  </div>
</template>
