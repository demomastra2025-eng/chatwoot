<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useWindowSize } from '@vueuse/core';
import { vOnClickOutside } from '@vueuse/components';
import { debounce } from '@chatwoot/utils';
import { useAlert } from 'dashboard/composables';
import { useKeyboardEvents } from 'dashboard/composables/useKeyboardEvents';
import { useOpenPersonDialog } from 'dashboard/composables/useOpenPersonDialog';
import {
  createContactSearcher,
  createNewContact,
} from 'dashboard/components-next/NewConversation/helpers/composeConversationHelper';

import wootConstants from 'dashboard/constants/globals';

import ContactSelector from 'dashboard/components-next/NewConversation/components/ContactSelector.vue';

// «Новое сообщение»: only finds (or creates) the person. The conversation itself is the dialog of the person, the same screen as
// everywhere else, and it exists only after the first message, see useOpenPersonDialog.
const props = defineProps({
  alignPosition: {
    type: String,
    default: 'left',
  },
  isModal: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['close']);

const { t } = useI18n();
const { openPersonDialog } = useOpenPersonDialog();
const searchContacts = createContactSearcher();

const { width: windowWidth } = useWindowSize();
const viewInModal = computed(
  () =>
    props.isModal || windowWidth.value < wootConstants.SMALL_SCREEN_BREAKPOINT
);

const isOpen = ref(false);
const contacts = ref([]);
const isSearching = ref(false);
const isCreatingContact = ref(false);
const showContactsDropdown = ref(false);

const popoverClass = computed(() => {
  if (viewInModal.value) return '';

  return props.alignPosition === 'right'
    ? 'absolute top-full mt-2 ltr:left-0 ltr:right-[unset] rtl:right-0 rtl:left-[unset]'
    : 'absolute top-full mt-2 rtl:left-0 rtl:right-[unset] ltr:right-0 ltr:left-[unset]';
});

const resetContacts = () => {
  contacts.value = [];
};

const onContactSearch = debounce(
  async query => {
    isSearching.value = true;
    contacts.value = [];
    try {
      const results = await searchContacts(query);
      // null means the request was aborted: a newer search is in flight
      if (results === null) return;
      contacts.value = results;
      showContactsDropdown.value = true;
      isSearching.value = false;
    } catch (error) {
      isSearching.value = false;
      useAlert(t('PERSON_DIALOG.PICKER.SEARCH_ERROR'));
    }
  },
  400,
  false
);

const close = () => {
  if (!isOpen.value) return;
  isOpen.value = false;
  showContactsDropdown.value = false;
  resetContacts();
  emit('close');
};

const toggle = () => {
  if (isOpen.value) {
    close();
    return;
  }
  isOpen.value = true;
};

const handleSelectedContact = async ({ value, action, ...rest }) => {
  let contact = rest;
  if (action === 'create') {
    isCreatingContact.value = true;
    try {
      contact = await createNewContact(value);
    } catch (error) {
      return;
    } finally {
      isCreatingContact.value = false;
    }
  }
  if (!contact?.id) return;

  close();
  await openPersonDialog(contact.id);
};

useKeyboardEvents({
  Escape: {
    action: () => close(),
  },
});

defineExpose({ toggle });
</script>

<template>
  <div
    v-on-click-outside="close"
    class="relative"
    :class="{ 'z-50': isOpen && !viewInModal }"
  >
    <slot name="trigger" :is-open="isOpen" :toggle="toggle" />
    <div
      v-if="isOpen"
      :class="{
        'fixed z-50 inset-0 flex items-start justify-center bg-n-alpha-black1 pt-[clamp(3rem,15vh,12rem)] backdrop-blur-[4px]':
          viewInModal,
      }"
      @click.self="viewInModal && close()"
    >
      <div
        class="w-[22rem] max-w-[calc(100vw-2rem)] overflow-visible rounded-xl border border-n-strong bg-n-alpha-3 shadow-sm backdrop-blur-[100px]"
        :class="popoverClass"
        data-test-id="person-picker"
      >
        <ContactSelector
          :contacts="contacts"
          :selected-contact="null"
          :show-contacts-dropdown="showContactsDropdown"
          :is-loading="isSearching"
          :is-creating-contact="isCreatingContact"
          :show-inboxes-dropdown="false"
          @search-contacts="onContactSearch"
          @set-selected-contact="handleSelectedContact"
          @clear-selected-contact="resetContacts"
          @update-dropdown="(_name, open) => (showContactsDropdown = open)"
        />
      </div>
    </div>
  </div>
</template>
