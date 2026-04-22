<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { dynamicTime } from 'shared/helpers/timeHelper';
import { useRoute, useRouter } from 'vue-router';
import camelcaseKeys from 'camelcase-keys';

import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ContactLabels from 'dashboard/components-next/Contacts/ContactLabels/ContactLabels.vue';
import ComposeConversation from 'dashboard/components-next/NewConversation/ComposeConversation.vue';
import ContactsForm from 'dashboard/components-next/Contacts/ContactsForm/ContactsForm.vue';
import ConfirmContactDeleteDialog from 'dashboard/components-next/Contacts/ContactsForm/ConfirmContactDeleteDialog.vue';
import Policy from 'dashboard/components/policy.vue';
import ContactIdentitySources from 'dashboard/routes/dashboard/conversation/contact/ContactIdentitySources.vue';
import {
  displayableIdentityDetail,
  getContactSourceIconClass,
  sourceValue,
} from 'dashboard/helper/contactIdentity';

const props = defineProps({
  selectedContact: {
    type: Object,
    required: true,
  },
});

const emit = defineEmits(['goToContactsList']);

const { t } = useI18n();
const store = useStore();
const route = useRoute();
const router = useRouter();

const confirmDeleteContactDialogRef = ref(null);
const composeConversationRef = ref(null);

const avatarFile = ref(null);
const avatarUrl = ref('');
const metadataSeparator = '•';

const contactsFormRef = ref(null);

const uiFlags = useMapGetter('contacts/getUIFlags');
const contactConversations = useMapGetter(
  'contactConversations/getAllConversationsByContactId'
);
const isUpdating = computed(() => uiFlags.value.isUpdating);

const isFormInvalid = computed(() => contactsFormRef.value?.isFormInvalid);

const contactData = ref({});

const getInitialContactData = () => {
  if (!props.selectedContact) return {};
  return { ...props.selectedContact };
};

const applyUpdatedContact = updatedContact => {
  if (!updatedContact) {
    return;
  }

  contactData.value = {
    ...contactData.value,
    ...camelcaseKeys(updatedContact, {
      deep: true,
      stopPaths: ['custom_attributes'],
    }),
  };
};

watch(
  () => props.selectedContact?.id,
  () => {
    avatarFile.value = null;
    avatarUrl.value = '';
    Object.assign(contactData.value, getInitialContactData());
  },
  { immediate: true }
);

const buildSourcePreference = (source, preferenceType = 'name') => {
  const resolvedSource =
    preferenceType === 'avatar'
      ? source.avatarSource || source
      : source.nameSource || source;

  return {
    kind: sourceValue(resolvedSource, 'kind') || 'channel_profile',
    contactInboxId: sourceValue(resolvedSource, 'contactInboxId'),
    inboxId: sourceValue(resolvedSource, 'inboxId'),
    channelType: sourceValue(resolvedSource, 'channelType'),
    provider: sourceValue(resolvedSource, 'provider'),
    sourceId: sourceValue(resolvedSource, 'sourceId'),
    identifier: sourceValue(resolvedSource, 'identifier'),
  };
};

const updateLocalDisplayPreference = (preferenceKey, preferenceValue) => {
  const additionalAttributes = {
    ...(contactData.value.additionalAttributes || {}),
  };
  const displayPreferences = {
    ...(additionalAttributes.displayPreferences || {}),
    [preferenceKey]: preferenceValue,
  };

  contactData.value = {
    ...contactData.value,
    additionalAttributes: {
      ...additionalAttributes,
      displayPreferences,
    },
    [preferenceKey]: preferenceValue,
  };
};

const displayIdentifier = computed(() =>
  displayableIdentityDetail(contactData.value?.identifier)
);

const primaryNameSource = computed(
  () =>
    contactData.value?.primaryNameSource ||
    contactData.value?.primary_name_source
);

const primaryAvatarSource = computed(
  () =>
    contactData.value?.primaryAvatarSource ||
    contactData.value?.primary_avatar_source
);

const primaryNameSourceIconClass = computed(() =>
  getContactSourceIconClass(primaryNameSource.value)
);

const primaryAvatarSourceIconClass = computed(() =>
  getContactSourceIconClass(primaryAvatarSource.value)
);

const hasPrimaryNameSourceBadge = computed(() =>
  Boolean(sourceValue(primaryNameSource.value, 'kind'))
);

const hasPrimaryAvatarSourceBadge = computed(() =>
  Boolean(sourceValue(primaryAvatarSource.value, 'kind'))
);

const hasIdentityAccordion = computed(() => {
  const contactInboxes = contactData.value?.contactInboxes || [];
  const channelProfiles =
    contactData.value?.channelProfiles ||
    contactData.value?.channel_profiles ||
    [];

  return contactInboxes.length > 0 || channelProfiles.length > 0;
});

const createdAt = computed(() => {
  return contactData.value?.createdAt
    ? dynamicTime(contactData.value.createdAt)
    : '';
});

const lastActivityAt = computed(() => {
  return contactData.value?.lastActivityAt
    ? dynamicTime(contactData.value.lastActivityAt)
    : '';
});

const avatarSrc = computed(() => {
  return avatarUrl.value ? avatarUrl.value : contactData.value?.thumbnail;
});

const handleFormUpdate = updatedData => {
  Object.assign(contactData.value, updatedData);
};

const updateContact = async () => {
  try {
    const { customAttributes, ...basicContactData } = contactData.value;
    const updatedContact = await store.dispatch(
      'contacts/update',
      basicContactData
    );
    applyUpdatedContact(updatedContact);
    await store.dispatch(
      'contacts/fetchContactableInbox',
      props.selectedContact.id
    );
    useAlert(t('CONTACTS_LAYOUT.CARD.EDIT_DETAILS_FORM.SUCCESS_MESSAGE'));
  } catch (error) {
    useAlert(t('CONTACTS_LAYOUT.CARD.EDIT_DETAILS_FORM.ERROR_MESSAGE'));
  }
};

const setPrimaryNameSource = async source => {
  const preference = buildSourcePreference(source, 'name');
  const displayName = sourceValue(source, 'displayName');

  try {
    const updatedContact = await store.dispatch('contacts/update', {
      id: props.selectedContact.id,
      name: displayName,
      additionalAttributes: {
        displayPreferences: {
          primaryNameSource: preference,
        },
      },
    });

    applyUpdatedContact(updatedContact);
    if (!updatedContact) {
      if (displayName) {
        contactData.value.name = displayName;
      }
      updateLocalDisplayPreference('primaryNameSource', preference);
    }
  } catch (error) {
    useAlert(t('CONTACT_FORM.ERROR_MESSAGE'));
  }
};

const setPrimaryAvatarSource = async source => {
  const preference = buildSourcePreference(source, 'avatar');
  const resolvedAvatarUrl = sourceValue(source, 'avatarUrl');

  try {
    const updatedContact = await store.dispatch('contacts/update', {
      id: props.selectedContact.id,
      additionalAttributes: {
        displayPreferences: {
          primaryAvatarSource: preference,
        },
      },
    });

    avatarUrl.value = '';
    applyUpdatedContact(updatedContact);
    if (!updatedContact) {
      if (resolvedAvatarUrl) {
        contactData.value.thumbnail = resolvedAvatarUrl;
      }
      updateLocalDisplayPreference('primaryAvatarSource', preference);
    }
  } catch (error) {
    useAlert(t('CONTACT_FORM.ERROR_MESSAGE'));
  }
};

const openConfirmDeleteContactDialog = () => {
  confirmDeleteContactDialogRef.value?.dialogRef.open();
};

const handleAvatarUpload = async ({ file, url }) => {
  avatarFile.value = file;
  avatarUrl.value = url;

  try {
    const updatedContact = await store.dispatch('contacts/update', {
      ...contactsFormRef.value?.state,
      avatar: file,
      isFormData: true,
    });
    applyUpdatedContact(updatedContact);
    useAlert(t('CONTACTS_LAYOUT.DETAILS.AVATAR.UPLOAD.SUCCESS_MESSAGE'));
  } catch {
    useAlert(t('CONTACTS_LAYOUT.DETAILS.AVATAR.UPLOAD.ERROR_MESSAGE'));
  }
};

const handleAvatarDelete = async () => {
  try {
    if (props.selectedContact && props.selectedContact.id) {
      const updatedContact = await store.dispatch(
        'contacts/deleteAvatar',
        props.selectedContact.id
      );
      applyUpdatedContact(updatedContact);
      useAlert(t('CONTACTS_LAYOUT.DETAILS.AVATAR.DELETE.SUCCESS_MESSAGE'));
    }
    avatarFile.value = null;
    avatarUrl.value = '';
  } catch (error) {
    useAlert(
      error.message
        ? error.message
        : t('CONTACTS_LAYOUT.DETAILS.AVATAR.DELETE.ERROR_MESSAGE')
    );
  }
};

const openChannelConversation = async channelIdentity => {
  const conversations =
    contactConversations.value(props.selectedContact?.id) || [];

  const targetConversation = conversations.find(
    conversation =>
      Number(conversation.inboxId || conversation.inbox_id) ===
      Number(channelIdentity.inboxId)
  );

  if (!targetConversation) {
    await composeConversationRef.value?.openWithChannel({
      contact: contactData.value,
      channelIdentity,
    });
    return;
  }

  router.push({
    name: 'inbox_view_conversation',
    params: {
      accountId: route.params.accountId,
      type: 'conversation',
      id: targetConversation.id,
    },
  });
};
</script>

<template>
  <div class="flex flex-col items-start gap-8 pb-6">
    <div class="flex w-full flex-col gap-5">
      <div class="flex min-w-0 flex-1 flex-col gap-4">
        <div class="flex items-start gap-4">
          <Avatar
            :src="avatarSrc || ''"
            :name="contactData?.name || ''"
            :size="72"
            allow-upload
            @upload="handleAvatarUpload"
            @delete="handleAvatarDelete"
          >
            <template #badge>
              <div
                v-if="hasPrimaryAvatarSourceBadge"
                class="absolute bottom-0 right-0 z-20 flex size-6 items-center justify-center rounded-full border border-n-slate-3 bg-n-solid-1 text-n-slate-11 shadow-sm"
              >
                <span
                  class="size-3.5 shrink-0"
                  :class="primaryAvatarSourceIconClass"
                />
              </div>
            </template>
          </Avatar>
          <div class="min-w-0 flex-1">
            <div class="relative inline-block max-w-full pr-7">
              <h3 class="mb-0 text-base font-medium text-n-slate-12">
                {{ contactData?.name }}
              </h3>
              <span
                v-if="hasPrimaryNameSourceBadge"
                class="absolute right-0 top-0 z-10 inline-flex size-5 items-center justify-center rounded-full border border-n-slate-3 bg-n-solid-1 text-n-slate-11 shadow-sm"
              >
                <span
                  class="size-3 shrink-0"
                  :class="primaryNameSourceIconClass"
                />
              </span>
            </div>
            <div class="mt-1 flex flex-col gap-1.5">
              <span
                v-if="displayIdentifier"
                class="inline-flex items-center gap-1 text-sm text-n-slate-11"
              >
                <span class="i-ph-user-gear text-n-slate-10 size-4" />
                {{ displayIdentifier }}
              </span>
              <span
                class="inline-flex items-center gap-1 text-sm text-n-slate-11"
              >
                <span class="i-ph-activity text-n-slate-10 size-4" />
                {{
                  $t('CONTACTS_LAYOUT.DETAILS.CREATED_AT', {
                    date: createdAt,
                  })
                }}
                {{ metadataSeparator }}
                {{
                  $t('CONTACTS_LAYOUT.DETAILS.LAST_ACTIVITY', {
                    date: lastActivityAt,
                  })
                }}
              </span>
            </div>
          </div>
        </div>

        <ContactLabels :contact-id="selectedContact?.id" />
        <details
          v-if="hasIdentityAccordion"
          class="identity-accordion w-full overflow-hidden rounded-2xl border border-n-weak bg-n-solid-1 p-2 shadow-sm"
        >
          <summary
            class="identity-accordion__summary flex cursor-pointer list-none items-center justify-between gap-3 rounded-xl border border-transparent bg-n-solid-1 px-3 py-3 transition-colors hover:border-n-weak hover:bg-n-alpha-1 [&::-webkit-details-marker]:hidden"
          >
            <div class="flex min-w-0 items-center gap-2">
              <span
                class="inline-flex size-8 shrink-0 items-center justify-center rounded-xl border border-n-weak bg-n-alpha-1 text-n-slate-11 shadow-sm"
              >
                <span class="i-lucide-id-card size-4 text-n-slate-10" />
              </span>
              <span class="text-sm font-medium text-n-slate-12">
                {{ t('CONTACT_PANEL.IDENTIFIERS') }}
              </span>
            </div>
            <span
              class="identity-accordion__chevron i-lucide-chevron-down size-4 shrink-0 text-n-slate-10"
              aria-hidden="true"
            />
          </summary>

          <div class="px-1 pb-1 pt-4">
            <ContactIdentitySources
              :contact="contactData"
              :is-updating="isUpdating"
              only-actionable
              hide-empty-state
              show-message-action
              show-identifiers
              @select-name-source="setPrimaryNameSource"
              @select-avatar-source="setPrimaryAvatarSource"
              @open-channel-conversation="openChannelConversation"
            />
          </div>
        </details>
        <ComposeConversation
          ref="composeConversationRef"
          :contact-id="String(selectedContact?.id || '')"
          is-modal
        />
      </div>
    </div>
    <div class="flex flex-col items-start gap-6">
      <ContactsForm
        ref="contactsFormRef"
        :contact-data="contactData"
        is-details-view
        @update="handleFormUpdate"
      />
      <Button
        :label="t('CONTACTS_LAYOUT.CARD.EDIT_DETAILS_FORM.UPDATE_BUTTON')"
        size="sm"
        :is-loading="isUpdating"
        :disabled="isUpdating || isFormInvalid"
        @click="updateContact"
      />
    </div>
    <Policy :permissions="['administrator']">
      <div
        class="flex flex-col items-start w-full gap-4 pt-6 border-t border-n-strong"
      >
        <div class="flex flex-col gap-2">
          <h6 class="text-base font-medium text-n-slate-12">
            {{ t('CONTACTS_LAYOUT.DETAILS.DELETE_CONTACT') }}
          </h6>
          <span class="text-sm text-n-slate-11">
            {{ t('CONTACTS_LAYOUT.DETAILS.DELETE_CONTACT_DESCRIPTION') }}
          </span>
        </div>
        <Button
          :label="t('CONTACTS_LAYOUT.DETAILS.DELETE_CONTACT')"
          color="ruby"
          @click="openConfirmDeleteContactDialog"
        />
      </div>
      <ConfirmContactDeleteDialog
        ref="confirmDeleteContactDialogRef"
        :selected-contact="selectedContact"
        @go-to-contacts-list="emit('goToContactsList')"
      />
    </Policy>
  </div>
</template>

<style scoped lang="scss">
.identity-accordion__chevron {
  transition: transform 0.2s ease;
}

.identity-accordion[open] .identity-accordion__summary {
  @apply border-n-weak bg-n-alpha-1;
}

.identity-accordion[open] .identity-accordion__chevron {
  transform: rotate(180deg);
}
</style>
