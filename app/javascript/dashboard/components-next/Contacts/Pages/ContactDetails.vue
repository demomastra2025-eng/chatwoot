<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { dynamicTime } from 'shared/helpers/timeHelper';
import { useRoute, useRouter } from 'vue-router';

import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ContactChannelLabels from 'dashboard/components-next/Contacts/ContactChannelLabels.vue';
import ContactLabels from 'dashboard/components-next/Contacts/ContactLabels/ContactLabels.vue';
import ComposeConversation from 'dashboard/components-next/NewConversation/ComposeConversation.vue';
import ContactsForm from 'dashboard/components-next/Contacts/ContactsForm/ContactsForm.vue';
import ConfirmContactDeleteDialog from 'dashboard/components-next/Contacts/ContactsForm/ConfirmContactDeleteDialog.vue';
import Policy from 'dashboard/components/policy.vue';
import ContactIdentitySources from 'dashboard/routes/dashboard/conversation/contact/ContactIdentitySources.vue';
import {
  displayContactSourceLabel,
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
const existingConversationInboxIds = computed(() => {
  const contactId = Number(props.selectedContact?.id);

  if (
    !contactId ||
    !Object.prototype.hasOwnProperty.call(
      store.state.contactConversations.records,
      contactId
    )
  ) {
    return null;
  }

  const conversations = contactConversations.value(contactId) || [];

  return [
    ...new Set(
      conversations
        .map(conversation =>
          Number(conversation.inboxId || conversation.inbox_id)
        )
        .filter(Boolean)
    ),
  ];
});

const isFormInvalid = computed(() => contactsFormRef.value?.isFormInvalid);

const contactData = ref({});

const getInitialContactData = () => {
  if (!props.selectedContact) return {};
  return { ...props.selectedContact };
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

const primaryNameSource = computed(
  () =>
    props.selectedContact?.primaryNameSource ||
    props.selectedContact?.primary_name_source
);

const primaryAvatarSource = computed(
  () =>
    props.selectedContact?.primaryAvatarSource ||
    props.selectedContact?.primary_avatar_source
);

const primaryNameSourceLabel = computed(() =>
  displayContactSourceLabel(primaryNameSource.value, t)
);

const primaryAvatarSourceLabel = computed(() =>
  displayContactSourceLabel(primaryAvatarSource.value, t)
);

const primaryNameSourceIconClass = computed(() =>
  getContactSourceIconClass(primaryNameSource.value)
);

const primaryAvatarSourceIconClass = computed(() =>
  getContactSourceIconClass(primaryAvatarSource.value)
);

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
    await store.dispatch('contacts/update', basicContactData);
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
    await store.dispatch('contacts/update', {
      id: props.selectedContact.id,
      name: displayName,
      additionalAttributes: {
        displayPreferences: {
          primaryNameSource: preference,
        },
      },
    });

    if (displayName) {
      contactData.value.name = displayName;
    }
    updateLocalDisplayPreference('primaryNameSource', preference);
  } catch (error) {
    useAlert(t('CONTACT_FORM.ERROR_MESSAGE'));
  }
};

const setPrimaryAvatarSource = async source => {
  const preference = buildSourcePreference(source, 'avatar');
  const resolvedAvatarUrl = sourceValue(source, 'avatarUrl');

  try {
    await store.dispatch('contacts/update', {
      id: props.selectedContact.id,
      additionalAttributes: {
        displayPreferences: {
          primaryAvatarSource: preference,
        },
      },
    });

    avatarUrl.value = '';
    if (resolvedAvatarUrl) {
      contactData.value.thumbnail = resolvedAvatarUrl;
    }
    updateLocalDisplayPreference('primaryAvatarSource', preference);
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
    await store.dispatch('contacts/update', {
      ...contactsFormRef.value?.state,
      avatar: file,
      isFormData: true,
    });
    useAlert(t('CONTACTS_LAYOUT.DETAILS.AVATAR.UPLOAD.SUCCESS_MESSAGE'));
  } catch {
    useAlert(t('CONTACTS_LAYOUT.DETAILS.AVATAR.UPLOAD.ERROR_MESSAGE'));
  }
};

const handleAvatarDelete = async () => {
  try {
    if (props.selectedContact && props.selectedContact.id) {
      await store.dispatch('contacts/deleteAvatar', props.selectedContact.id);
      useAlert(t('CONTACTS_LAYOUT.DETAILS.AVATAR.DELETE.SUCCESS_MESSAGE'));
    }
    avatarFile.value = null;
    avatarUrl.value = '';
    contactData.value.thumbnail = null;
    contactData.value.contactAvatarUrl = null;
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
      contact: props.selectedContact,
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
            :name="selectedContact?.name || ''"
            :size="72"
            allow-upload
            @upload="handleAvatarUpload"
            @delete="handleAvatarDelete"
          />
          <div class="min-w-0 flex-1">
            <h3 class="mb-0 text-base font-medium text-n-slate-12">
              {{ selectedContact?.name }}
            </h3>
            <div class="mt-1 flex flex-col gap-1.5">
              <span
                v-if="selectedContact?.identifier"
                class="inline-flex items-center gap-1 text-sm text-n-slate-11"
              >
                <span class="i-ph-user-gear text-n-slate-10 size-4" />
                {{ selectedContact?.identifier }}
              </span>
              <span
                class="inline-flex items-center gap-1 text-sm text-n-slate-11"
              >
                <span
                  v-if="selectedContact?.identifier"
                  class="i-ph-activity text-n-slate-10 size-4"
                />
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
            <div
              class="mt-3 flex flex-wrap items-center gap-2 text-xs text-n-slate-11"
            >
              <span
                class="inline-flex items-center gap-1 rounded-full bg-n-alpha-2 px-2.5 py-1 text-n-slate-11"
              >
                <span class="font-medium text-n-slate-12">
                  {{ $t('CONTACT_PANEL.SOURCE_IDENTITIES.PRIMARY_NAME') }}
                </span>
                <span
                  class="inline-flex items-center gap-1 rounded-full bg-n-solid-1 px-2 py-0.5 text-n-slate-12"
                >
                  <span
                    class="text-sm leading-none"
                    :class="primaryNameSourceIconClass"
                  />
                  <span>{{ primaryNameSourceLabel }}</span>
                </span>
              </span>
              <span
                class="inline-flex items-center gap-1 rounded-full bg-n-alpha-2 px-2.5 py-1 text-n-slate-11"
              >
                <span class="font-medium text-n-slate-12">
                  {{ $t('CONTACT_PANEL.SOURCE_IDENTITIES.PRIMARY_PHOTO') }}
                </span>
                <span
                  class="inline-flex items-center gap-1 rounded-full bg-n-solid-1 px-2 py-0.5 text-n-slate-12"
                >
                  <span
                    class="text-sm leading-none"
                    :class="primaryAvatarSourceIconClass"
                  />
                  <span>{{ primaryAvatarSourceLabel }}</span>
                </span>
              </span>
            </div>
          </div>
        </div>

        <ContactIdentitySources
          :contact="selectedContact"
          :is-updating="isUpdating"
          @select-name-source="setPrimaryNameSource"
          @select-avatar-source="setPrimaryAvatarSource"
        />

        <ContactLabels :contact-id="selectedContact?.id" />
        <ContactChannelLabels
          :contact-inboxes="selectedContact?.contactInboxes || []"
          :existing-conversation-inbox-ids="existingConversationInboxIds"
          :title="t('CONTACT_PANEL.CHANNEL_IDENTITIES')"
          :copy-on-click="false"
          @select="openChannelConversation"
        />
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
