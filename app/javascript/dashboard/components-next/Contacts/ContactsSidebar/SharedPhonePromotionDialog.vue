<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

// Confirmation for M5(b)+M6: shows exactly which chats of the number move to the patient, what stays with the
// previous holder, and that the transfer is logged and can be reverted.
const props = defineProps({
  preview: {
    type: Object,
    default: null,
  },
  patientName: {
    type: String,
    default: '',
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['confirm']);

const { t } = useI18n();
const dialogRef = ref(null);

const ownerName = computed(() => props.preview?.previous_holder?.name || '');
const conversations = computed(() => props.preview?.conversations || []);
const movesChats = computed(() => conversations.value.length > 0);
const notMovedHolders = computed(
  () => (props.preview?.not_moved_other_holders || []).length
);
const notMovedLidChats = computed(
  () => props.preview?.not_moved_lid_chats_count || 0
);
const siblingNames = computed(() =>
  (props.preview?.siblings || []).map(sibling => sibling.name).join(', ')
);

const open = () => dialogRef.value?.open();
const close = () => dialogRef.value?.close();

defineExpose({ open, close });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="edit"
    :title="t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.DIALOG_TITLE')"
    :confirm-button-label="
      t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.DIALOG_CONFIRM')
    "
    :is-loading="isLoading"
    :disable-confirm-button="!preview"
    @confirm="emit('confirm')"
  >
    <div
      v-if="preview"
      class="flex flex-col gap-2 text-sm text-n-slate-12"
      data-testid="shared-phone-promotion-dialog"
    >
      <p class="mb-0">
        {{
          t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.DIALOG_NUMBER', {
            phone: preview.masked_phone,
            patient: patientName,
          })
        }}
      </p>
      <p v-if="movesChats" class="mb-0" data-testid="shared-phone-moves">
        {{
          t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.DIALOG_MOVES', {
            owner: ownerName,
            patient: patientName,
            chats: conversations.length,
            messages: preview.messages_count,
          })
        }}
      </p>
      <p v-else class="mb-0" data-testid="shared-phone-moves-nothing">
        {{ t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.DIALOG_NOTHING_MOVES') }}
      </p>
      <ul v-if="movesChats" class="mb-0 ltr:pl-4 rtl:pr-4 list-disc">
        <li
          v-for="conversation in conversations"
          :key="conversation.display_id"
        >
          {{
            t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.DIALOG_CHAT', {
              id: conversation.display_id,
              inbox: conversation.inbox_name,
              messages: conversation.messages_count,
            })
          }}
        </li>
      </ul>
      <p v-if="ownerName" class="mb-0 text-n-slate-11">
        {{
          t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.DIALOG_STAYS', {
            owner: ownerName,
          })
        }}
      </p>
      <p
        v-if="notMovedHolders || notMovedLidChats"
        class="mb-0 text-n-slate-11"
      >
        {{
          t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.DIALOG_NOT_MOVED', {
            holders: notMovedHolders,
            lid: notMovedLidChats,
          })
        }}
      </p>
      <p v-if="siblingNames" class="mb-0 text-n-slate-11">
        {{
          t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.HINT_SIBLINGS', {
            names: siblingNames,
          })
        }}
      </p>
      <p class="mb-0 text-n-slate-11">
        {{ t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.DIALOG_AUDIT') }}
      </p>
    </div>
  </Dialog>
</template>
