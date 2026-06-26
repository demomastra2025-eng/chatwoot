<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { INPUT_TYPES } from 'dashboard/components-next/taginput/helper/tagInputHelper.js';

import TagInput from 'dashboard/components-next/taginput/TagInput.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  contacts: {
    type: Array,
    required: true,
  },
  selectedContact: {
    type: Object,
    default: null,
  },
  showContactsDropdown: {
    type: Boolean,
    required: true,
  },
  isLoading: {
    type: Boolean,
    required: true,
  },
  isCreatingContact: {
    type: Boolean,
    required: true,
  },
  contactId: {
    type: String,
    default: null,
  },
  contactableInboxesList: {
    type: Array,
    default: () => [],
  },
  showInboxesDropdown: {
    type: Boolean,
    required: true,
  },
  hasErrors: {
    type: Boolean,
    default: false,
  },
  variant: {
    type: String,
    default: 'default',
    validator: value => ['default', 'touch'].includes(value),
  },
});

const emit = defineEmits([
  'searchContacts',
  'setSelectedContact',
  'clearSelectedContact',
  'updateDropdown',
]);

const { t } = useI18n();

const inputType = ref(INPUT_TYPES.EMAIL);
const isTouchVariant = computed(() => props.variant === 'touch');

const contactsList = computed(() => {
  return props.contacts?.map(({ name, id, thumbnail, email, ...rest }) => ({
    id,
    label: email ? `${name} (${email})` : name,
    value: id,
    thumbnail: { name, src: thumbnail },
    ...rest,
    name,
    email,
    action: 'contact',
  }));
});

const selectedContactLabel = computed(() => {
  const { name, email = '', phoneNumber = '' } = props.selectedContact || {};
  if (email) {
    return `${name} (${email})`;
  }
  if (phoneNumber) {
    return `${name} (${phoneNumber})`;
  }
  return name || '';
});

const selectedContactAvatarName = computed(() => {
  return props.selectedContact?.name || selectedContactLabel.value || 'Contact';
});

const selectedContactAvatarSrc = computed(() => {
  return (
    props.selectedContact?.thumbnail || props.selectedContact?.avatar || ''
  );
});

const errorClass = computed(() => {
  return props.hasErrors
    ? '[&_input]:placeholder:!text-n-ruby-9 [&_input]:dark:placeholder:!text-n-ruby-9'
    : '';
});

const handleInput = value => {
  // Update input type based on whether input starts with '+'
  // If it does, set input type to 'tel'
  // Otherwise, set input type to 'email'
  inputType.value = value.startsWith('+') ? INPUT_TYPES.TEL : INPUT_TYPES.EMAIL;
  emit('searchContacts', value);
};
</script>

<template>
  <div
    class="relative flex-1 overflow-y-visible"
    :class="isTouchVariant ? 'px-3 py-2' : 'px-4 py-3'"
  >
    <div
      class="flex w-full gap-3 min-h-7"
      :class="isTouchVariant ? 'items-center' : 'items-baseline'"
    >
      <label
        class="text-sm font-medium whitespace-nowrap"
        :class="isTouchVariant ? 'text-n-slate-12 min-w-14' : 'text-n-slate-11'"
      >
        {{ t('COMPOSE_NEW_CONVERSATION.FORM.CONTACT_SELECTOR.LABEL') }}
      </label>

      <div
        v-if="isCreatingContact"
        class="flex items-center gap-1.5 min-w-0"
        :class="
          isTouchVariant
            ? 'min-h-9 flex-1 rounded-lg border border-n-weak bg-n-solid-1 px-2.5'
            : 'rounded-md bg-n-alpha-2 px-4 min-h-7'
        "
      >
        <Avatar
          v-if="isTouchVariant"
          name="Contact"
          icon-name="i-lucide-user-plus"
          :size="24"
          rounded-full
        />
        <span class="text-sm truncate text-n-slate-12">
          {{
            t('COMPOSE_NEW_CONVERSATION.FORM.CONTACT_SELECTOR.CONTACT_CREATING')
          }}
        </span>
      </div>
      <div
        v-else-if="selectedContact"
        class="flex items-center gap-1.5 min-w-0"
        :class="[
          isTouchVariant
            ? 'min-h-9 flex-1 rounded-lg border border-n-weak bg-n-solid-1'
            : 'rounded-md bg-n-alpha-2 min-h-7',
          !contactId
            ? isTouchVariant
              ? 'ltr:pl-2 rtl:pr-2 ltr:pr-1.5 rtl:pl-1.5'
              : 'ltr:pl-4 rtl:pr-4 ltr:pr-1.5 rtl:pl-1.5'
            : isTouchVariant
              ? 'px-2'
              : 'px-4',
        ]"
      >
        <Avatar
          v-if="isTouchVariant"
          :src="selectedContactAvatarSrc"
          :name="selectedContactAvatarName"
          :size="24"
          rounded-full
        />
        <span class="text-sm truncate text-n-slate-12">
          {{
            isCreatingContact
              ? t(
                  'COMPOSE_NEW_CONVERSATION.FORM.CONTACT_SELECTOR.CONTACT_CREATING'
                )
              : selectedContactLabel
          }}
        </span>
        <Button
          v-if="!contactId"
          variant="ghost"
          icon="i-lucide-x"
          color="slate"
          :disabled="contactId"
          size="xs"
          @click="emit('clearSelectedContact')"
        />
      </div>
      <TagInput
        v-else
        :placeholder="
          t(
            'COMPOSE_NEW_CONVERSATION.FORM.CONTACT_SELECTOR.TAG_INPUT_PLACEHOLDER'
          )
        "
        mode="single"
        :menu-items="contactsList"
        :show-dropdown="showContactsDropdown"
        :is-loading="isLoading"
        :disabled="contactableInboxesList?.length > 0 && showInboxesDropdown"
        allow-create
        :type="inputType"
        :class="[
          errorClass,
          isTouchVariant ? 'flex-1 min-h-9' : 'flex-1 min-h-7',
        ]"
        focus-on-mount
        @input="handleInput"
        @on-click-outside="emit('updateDropdown', 'contacts', false)"
        @add="emit('setSelectedContact', $event)"
        @remove="emit('clearSelectedContact')"
      />
    </div>
  </div>
</template>
